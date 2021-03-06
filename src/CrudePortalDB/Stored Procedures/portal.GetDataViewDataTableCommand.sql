﻿/*
-- Sample Usage:
DECLARE @SearchValue NVARCHAR(MAX) = N'8'
DECLARE @ColumnsOptions XML = N'
<Columns>
	<Column ColIndex="1" Name="Field_1" DataSrc="NavLabel" RegEx="False"/>
	<Column ColIndex="2" Name="Field_2" DataSrc="NavParentId" RegEx="False"/>
	<Column ColIndex="3" Name="Field_3" DataSrc="NavOrder" RegEx="False"/>
	<Column ColIndex="4" Name="Field_4" DataSrc="NavUri" RegEx="False"/>
	<Column ColIndex="5" Name="Field_5" DataSrc="NavGlyph" RegEx="False"/>
	<Column ColIndex="6" Name="Field_6" DataSrc="NavTooltip" RegEx="False"/>
	<Column ColIndex="7" Name="Field_7" DataSrc="ViewID" RegEx="False"/>
	<Column ColIndex="8" Name="Field_8" DataSrc="OpenUriInIFRAME" RegEx="False"/>
</Columns>'

DECLARE @ColumnsOrder XML = N'
<Order>
	<Column ColIndex="2" Direction="asc"/>
	<Column ColIndex="1" Direction="desc"/>
</Order>'

DECLARE @Results TABLE (DataSource NVARCHAR(4000), SQLCMD NVARCHAR(MAX)); --, Params NVARCHAR(4000));
INSERT INTO @Results
EXEC [portal].[GetDataViewDataTableCommand] @ViewID = 1, @Draw = 1, @Start = 1, @Length = 25, @SearchValue = @SearchValue, @ColumnsOptions = @ColumnsOptions, @ColumnsOrder = @ColumnsOrder

DECLARE @SQL NVARCHAR(MAX), @Params NVARCHAR(4000)

SELECT @SQL = SQLCMD --, @Params = Params
FROM @Results
PRINT @SQL
EXEC sp_executesql @SQL, N'@ColumnsOptions XML, @Start INT, @Length INT, @SearchValue NVARCHAR(MAX)'
	, @ColumnsOptions, 1, 10, @SearchValue

*/
CREATE PROCEDURE [portal].[GetDataViewDataTableCommand]
	@ViewID INT,
	@Draw INT = 1,
	@Start INT = 1,
	@Length INT = 25,
	@SearchValue NVARCHAR(MAX) = NULL,
	@SearchRegEx BIT = 0, -- not yet implemented
	@ColumnsOptions XML = NULL,
	@ColumnsOrder XML = NULL,
	@FilteringByPK BIT = 0
AS
SET NOCOUNT ON;
DECLARE @DataSource NVARCHAR(100), @TableName NVARCHAR(300), @PK NVARCHAR(300), @Flags INT, @RowReorder NVARCHAR(200)
DECLARE @CMD NVARCHAR(MAX), @SQLColumns NVARCHAR(MAX)

SELECT @DataSource = DataSource, @TableName = MainTable, @PK = Primarykey, @Flags = Flags, @RowReorder = NULLIF(RowReorderColumn, '')
FROM portal.DataView
WHERE ViewID = @ViewID

DECLARE
	@ParametersDeclaration NVARCHAR(MAX) = N'',
	@ParametersFilter NVARCHAR(MAX) = N'',
	@QuickFilter NVARCHAR(MAX) = N'',
	@OrderBy NVARCHAR(MAX) = NULL,
	@StopFiltering BIT = 0

SET @SQLColumns = N'
SELECT [DT_RowId] = ' + @PK + N', [DT_RowIndex] = ROW_NUMBER() OVER (ORDER BY '

IF @ColumnsOrder IS NOT NULL
BEGIN
	;WITH ColsXML
	AS
	(
		SELECT
			ColIndex = X.value('(@ColIndex)[1]', 'int'),
			ColName = X.value('(@Name)[1]', 'nvarchar(max)'),
			DataSrc = X.value('(@DataSrc)[1]', 'nvarchar(max)'),
			IsRegEx = X.value('(@RegEx)[1]', 'bit'),
			SearchVal = X.value('(text())[1]', 'nvarchar(max)')
		FROM @ColumnsOptions.nodes('/Columns/Column') AS T(X)
		WHERE @RowReorder IS NULL
		UNION ALL
		SELECT
			ColIndex = 0,
			ColName = @RowReorder,
			DataSrc = @RowReorder,
			IsRegEx = 0,
			SearchVal = NULL
		WHERE @RowReorder IS NOT NULL
	)
	SELECT
		@SQLColumns = @SQLColumns + N'
				ISNULL(CONVERT(nvarchar(max), ' + FieldSource + N'), '''') ' + CASE co.ColDir WHEN 'desc' THEN 'DESC' ELSE 'ASC' END + N', '
	FROM  portal.DataViewField AS dvf
	INNER JOIN ColsXML AS c
	ON (@RowReorder IS NULL AND CONVERT(nvarchar,dvf.FieldIdentifier) = c.ColName)
	OR (@RowReorder IS NOT NULL AND dvf.FieldSource = @RowReorder)
	INNER JOIN (
	SELECT
		ColIndex = X.value('(@ColIndex)[1]', 'int'),
		ColDir = X.value('(@Direction)[1]', 'varchar(4)')
	FROM @ColumnsOrder.nodes('/Order/Column') AS T(X)
	) AS co
	ON c.ColIndex = co.ColIndex
	WHERE ViewID = @ViewID

	-- Remove trailing comma
	IF @@ROWCOUNT > 0
		SET @SQLColumns = LEFT(@SQLColumns, LEN(@SQLColumns) - 1)
END
ELSE
	SET @SQLColumns = @SQLColumns + ISNULL(@RowReorder, @PK)

SET @SQLColumns = @SQLColumns + N')'

-- Prepare indexed temp table to force sorting on the columns
IF OBJECT_ID('tempdb..#Columns') IS NOT NULL DROP TABLE #Columns;
CREATE TABLE #Columns
(
  ColIndex int NULL, DataSrc nvarchar(1000) NULL, IsRegEx bit NULL, SearchVal nvarchar(max) NULL, OperandTemplate nvarchar(200) NULL
, FieldType nvarchar(50) NOT NULL, FieldSource nvarchar(300) NULL
, FieldOrder int NOT NULL
);
CREATE CLUSTERED INDEX IX ON #Columns (FieldOrder ASC);

;WITH ColsXML
AS
(
	SELECT
		ColIndex = X.value('(@ColIndex)[1]', 'int'),
		ColName = CASE WHEN @FilteringByPK = 1 THEN NULL ELSE X.value('(@Name)[1]', 'nvarchar(1000)') END,
		DataSrc = CASE WHEN @FilteringByPK = 1 THEN NULL ELSE X.value('(@DataSrc)[1]', 'nvarchar(1000)') END,
		IsRegEx = X.value('(@RegEx)[1]', 'bit'),
		SearchVal = X.value('(text())[1]', 'nvarchar(max)'),
		OperandTemplate = CASE WHEN @FilteringByPK = 1
							THEN N'
	AND ' + @PK + N' = {Parameter}'
							ELSE N'
	AND {Column} LIKE {Parameter}'
						  END
	FROM @ColumnsOptions.nodes('/Columns/Column') AS T(X)
)
INSERT INTO #Columns
SELECT
	  c.ColIndex
	, DataSrc = COALESCE(c.DataSrc, dvf.FieldIdentifier, 'Field_' + CONVERT(nvarchar,dvf.FieldID))
	, c.IsRegEx
	, c.SearchVal
	, c.OperandTemplate
	, dvf.FieldType
	, dvf.FieldSource
	, FieldOrder = ROW_NUMBER() OVER (ORDER BY dvf.FieldOrder ASC, dvf.FieldID ASC)
FROM portal.DataViewField AS dvf
LEFT JOIN ColsXML AS c
ON CONVERT(nvarchar,dvf.FieldIdentifier) = c.ColName
OR (@FilteringByPK = 1 AND c.ColIndex = 0)
WHERE ViewID = @ViewID;

SELECT
	@ParametersDeclaration = @ParametersDeclaration +
	CASE
		WHEN @StopFiltering = 0 AND SearchVal <> N'' THEN N'
	DECLARE @pFilter' + CONVERT(nvarchar, c.ColIndex) + N' nvarchar(max);
	SET @pFilter' + CONVERT(nvarchar, c.ColIndex) + N' = @ColumnsOptions.value(''(Columns/Column[@ColIndex="' + CONVERT(nvarchar, c.ColIndex) + N'"]/text())[1]'', ''nvarchar(max)'');'
		ELSE N''
	END
	,@ParametersFilter = @ParametersFilter +
	CASE
		WHEN @StopFiltering = 0 AND c.SearchVal <> N'' THEN
		REPLACE(REPLACE(OperandTemplate
			, N'{Column}', N'ISNULL(CONVERT(nvarchar(max), ' + FieldSource + N'), '''')')
			, N'{Parameter}', N'@pFilter' + CONVERT(nvarchar, c.ColIndex))
		ELSE N''
	END
	,@QuickFilter = @QuickFilter +
	CASE
		WHEN @FilteringByPK = 0 AND @SearchValue IS NOT NULL THEN N'
		OR ISNULL(CONVERT(nvarchar(max), ' + FieldSource + N'), '''') LIKE ''%'' + @SearchValue + ''%'''
		ELSE N''
	END
	,@SQLColumns = @SQLColumns + N',
		' + QUOTENAME(c.DataSrc) + N' = ' + CASE WHEN FieldType = 12 THEN N'''''' WHEN FieldType IN (7,8) THEN N'ISNULL(CONVERT(nvarchar(19),' + FieldSource + N', 126), '''')' ELSE N'ISNULL(CONVERT(nvarchar(max), ' + FieldSource + N'), '''')' END
	,@StopFiltering = @FilteringByPK
FROM #Columns AS c

SET @CMD = N'DECLARE @RTotal INT, @RFiltered INT;
DECLARE @ColumnsOptions XML, @Start INT, @Length INT, @SearchValue NVARCHAR(MAX)
SELECT @ColumnsOptions = ?, @Start = ?, @Length = ?, @SearchValue = ?

SELECT @RTotal = COUNT(*) FROM ' + @TableName + N';
' + @ParametersDeclaration

IF @ParametersFilter <> '' OR @QuickFilter <> ''
BEGIN
	SET @CMD = @CMD + '
	SELECT @RFiltered = COUNT(*) FROM ' + @TableName + N' WHERE 1=1'
	IF @ParametersFilter <> '' SET @CMD = @CMD + @ParametersFilter
	IF @QuickFilter <> '' SET @CMD = @CMD + N'
AND (1=0 ' + @QuickFilter + N')'
END
ELSE
	SET @CMD = @CMD + '
SET @RFiltered = @RTotal;'

SET @CMD = @CMD + N'
SELECT @RTotal AS recordsTotal, @RFiltered AS recordsFiltered

SELECT [JsonData] = ISNULL((SELECT * FROM (' + @SQLColumns + N' FROM ' + @TableName + N' WHERE 1=1'
IF @ParametersFilter <> '' SET @CMD = @CMD + @ParametersFilter
IF @QuickFilter <> '' SET @CMD = @CMD + N'
AND (1=0 ' + @QuickFilter + N')'

SET @CMD = @CMD + N'
) AS q
WHERE [DT_RowIndex] BETWEEN @Start AND @Start + @Length - 1'


SET @CMD = @CMD + N' FOR JSON AUTO), N''[ ]'')'

SELECT ISNULL(@DataSource, 'Default') AS DataSource, @CMD AS Command