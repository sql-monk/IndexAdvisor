-- Зовнішні ключі бази з колонками та індексом, на який спирається кожен FK (key_index_id).
SELECT
	fk.object_id AS foreignKeyId,
	fk.name AS foreignKeyName,
	fk.parent_object_id AS parentObjectId,
	fk.referenced_object_id AS referencedObjectId,
	OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS referencedSchema,
	OBJECT_NAME(fk.referenced_object_id) AS referencedTable,
	fk.key_index_id AS keyIndexId,
	ri.name AS referencedIndexName,
	fk.is_disabled AS isDisabled,
	fk.is_not_trusted AS isNotTrusted,
	fkc.constraint_column_id AS columnOrdinal,
	pc.name AS columnName,
	rc.name AS referencedColumnName
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
INNER JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
LEFT JOIN sys.indexes AS ri ON ri.object_id = fk.referenced_object_id AND ri.index_id = fk.key_index_id
ORDER BY fk.object_id, fkc.constraint_column_id;
