-- Колонки таблиць та індексованих представлень (базовий тип для псевдонімів типів).
SELECT
	c.object_id AS objectId,
	c.column_id AS columnId,
	c.name AS columnName,
	CASE WHEN ty.is_user_defined = 1 AND ty.is_assembly_type = 0 THEN TYPE_NAME(ty.system_type_id) ELSE ty.name END AS typeName,
	CAST(c.max_length AS INT) AS maxLength,
	CAST(c.precision AS INT) AS columnPrecision,
	CAST(c.scale AS INT) AS columnScale,
	c.is_nullable AS isNullable,
	c.is_computed AS isComputed,
	c.is_identity AS isIdentity,
	c.is_rowguidcol AS isRowGuidCol
FROM sys.columns AS c
INNER JOIN sys.objects AS o ON o.object_id = c.object_id
INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
WHERE o.is_ms_shipped = 0
	AND (o.type = 'U' OR (o.type = 'V' AND EXISTS (SELECT 1 FROM sys.indexes AS vi WHERE vi.object_id = o.object_id AND vi.index_id = 1)))
ORDER BY c.object_id, c.column_id;
