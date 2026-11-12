# Розбір XML showplan із Query Store у PowerShell (ТЗ 4.3.1; CONTRACTS.md 3.2). Сирий XML у snapshot не потрапляє.

$script:IaColShowplanNs = 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'

function Test-IaColPlanObjectSkipped {
	<# Тимчасові таблиці, табличні змінні та системні об'єкти не аналізуються. #>
	param([AllowNull()][string]$Database, [AllowNull()][string]$Schema, [AllowNull()][string]$Table)
	if ([string]::IsNullOrEmpty($Table)) {
		return $true
	}
	if ($Table.StartsWith('#') -or $Table.StartsWith('@')) {
		return $true
	}
	if ($Database -eq 'tempdb' -or $Database -eq 'mssqlsystemresource' -or $Schema -eq 'sys') {
		return $true
	}
	return $false
}

function Get-IaColPlanOperation {
	<# PhysicalOp -> Seek|Scan|Lookup|Update або $null (оператор без доступу до індексу). #>
	param([AllowNull()][string]$PhysicalOp, [System.Xml.XmlElement]$OperatorElement)
	if ([string]::IsNullOrEmpty($PhysicalOp) -or $PhysicalOp -like 'Remote*') {
		return $null
	}
	if ($PhysicalOp -like '*Lookup*' -or ($OperatorElement -and $OperatorElement.GetAttribute('Lookup') -in @('1', 'true'))) {
		return 'Lookup'
	}
	if ($PhysicalOp -like '*Seek*') {
		return 'Seek'
	}
	if ($PhysicalOp -like '*Scan*') {
		return 'Scan'
	}
	if ($PhysicalOp -match '(Insert|Update|Delete|Merge)$') {
		return 'Update'
	}
	return $null
}

function Get-IaColPlanColumnRefs {
	<# ColumnReference з атрибутом Table (колонки таблиць, не параметри) у межах вузла. #>
	param([System.Xml.XmlNode]$Node, [System.Xml.XmlNamespaceManager]$Ns, [string]$XPath = './/p:ColumnReference[@Table]')
	if ($null -eq $Node) {
		return , @()
	}
	return , @($Node.SelectNodes($XPath, $Ns))
}

function Add-IaColPlanPredicate {
	<# Додає предикат (без дублікатів) з ColumnReference. #>
	param($List, $Seen, [System.Xml.XmlElement]$ColumnRef, [string]$Operator, [string]$DefaultDatabase)
	$database = Get-IaColUnquotedName $ColumnRef.GetAttribute('Database')
	$schema = Get-IaColUnquotedName $ColumnRef.GetAttribute('Schema')
	$table = Get-IaColUnquotedName $ColumnRef.GetAttribute('Table')
	$column = Get-IaColUnquotedName $ColumnRef.GetAttribute('Column')
	if ([string]::IsNullOrEmpty($database)) {
		$database = $DefaultDatabase
	}
	if ((Test-IaColPlanObjectSkipped -Database $database -Schema $schema -Table $table) -or [string]::IsNullOrEmpty($column) -or $column -like 'PtnId*') {
		return
	}
	if ([string]::IsNullOrEmpty($schema)) {
		$schema = 'dbo'
	}
	$key = ('{0}|{1}|{2}|{3}' -f $schema, $table, $column, $Operator).ToLowerInvariant()
	if ($Seen.Add($key)) {
		$List.Add([ordered]@{ schema = $schema; table = $table; column = $column; operator = $Operator })
	}
}

function ConvertFrom-IaColShowplan {
	<# Розбирає XML showplan. Повертає @{ indexOperations; missingIndexes; predicates; hasKeyLookup; hasImplicitConversion; usesBatchMode;
	   scansWholeTable; partitionElimination; columnstoreSegmentElimination; parseError }. Невалідний XML — parseError і запасний
	   розбір посилань на індекси регулярним виразом (operation = $null: використання є, тип невідомий). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$PlanXml,
		[string]$DefaultDatabase
	)
	$result = [ordered]@{
		indexOperations = [System.Collections.Generic.List[object]]::new()
		missingIndexes = [System.Collections.Generic.List[object]]::new()
		predicates = [System.Collections.Generic.List[object]]::new()
		hasKeyLookup = $false
		hasImplicitConversion = $false
		usesBatchMode = $false
		scansWholeTable = $false
		partitionElimination = 'NotApplicable'
		columnstoreSegmentElimination = 'NotApplicable'
		parseError = $null
	}
	$document = [System.Xml.XmlDocument]::new()
	$document.XmlResolver = $null
	try {
		$settings = [System.Xml.XmlReaderSettings]::new()
		$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
		$settings.XmlResolver = $null
		$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($PlanXml), $settings)
		try {
			$document.Load($reader)
		}
		finally {
			$reader.Dispose()
		}
	}
	catch {
		$result.parseError = $_.Exception.Message
		$seenFallback = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($match in [regex]::Matches($PlanXml, '<Object\s[^>]*>')) {
			$tag = $match.Value
			$attributes = @{}
			foreach ($attribute in [regex]::Matches($tag, '(\w+)="([^"]*)"')) {
				$attributes[$attribute.Groups[1].Value] = $attribute.Groups[2].Value
			}
			$database = Get-IaColUnquotedName $attributes['Database']
			if ([string]::IsNullOrEmpty($database)) {
				$database = $DefaultDatabase
			}
			$schema = Get-IaColUnquotedName $attributes['Schema']
			$table = Get-IaColUnquotedName $attributes['Table']
			if (Test-IaColPlanObjectSkipped -Database $database -Schema $schema -Table $table) {
				continue
			}
			$index = Get-IaColUnquotedName $attributes['Index']
			if ($null -eq $index) {
				$index = ''
			}
			if ($seenFallback.Add("$database|$schema|$table|$index")) {
				$result.indexOperations.Add([ordered]@{ database = $database; schema = $schema; table = $table; index = $index; operation = $null; executionMode = $null; isHinted = $false })
			}
		}
		$result.partitionElimination = 'Unknown'
		$result.columnstoreSegmentElimination = 'Unknown'
		$result.scansWholeTable = $null
		return $result
	}
	$ns = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
	$ns.AddNamespace('p', $script:IaColShowplanNs)
	$seenPredicates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$seenOperations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$partitionedOps = 0
	$partitionSeeks = 0
	$columnstoreOps = 0
	$columnstoreWithPredicate = 0
	foreach ($relOp in @($document.SelectNodes('//p:RelOp', $ns))) {
		$physicalOp = $relOp.GetAttribute('PhysicalOp')
		$mode = $relOp.GetAttribute('EstimatedExecutionMode')
		if ([string]::IsNullOrEmpty($mode)) {
			$mode = $relOp.GetAttribute('ActualExecutionMode')
		}
		if ($mode -eq 'Batch') {
			$result.usesBatchMode = $true
		}
		$executionMode = if ($mode -in @('Row', 'Batch')) { $mode } else { $null }
		$isPartitioned = $relOp.GetAttribute('Partitioned') -in @('1', 'true')
		$operatorElement = $relOp.SelectSingleNode('p:IndexScan|p:TableScan|p:Update|p:SimpleUpdate|p:CreateIndex', $ns)
		$operation = Get-IaColPlanOperation -PhysicalOp $physicalOp -OperatorElement $operatorElement
		if ($null -eq $operation -or $null -eq $operatorElement) {
			continue
		}
		if ($operation -eq 'Lookup') {
			$result.hasKeyLookup = $true
		}
		$seekPredicates = $operatorElement.SelectSingleNode('p:SeekPredicates', $ns)
		if ($isPartitioned) {
			$partitionedOps++
			if ($seekPredicates -and $seekPredicates.SelectSingleNode(".//p:ColumnReference[starts-with(@Column, 'PtnId')]", $ns)) {
				$partitionSeeks++
			}
		}
		$isHinted = ($operatorElement.GetAttribute('ForcedIndex') -in @('1', 'true')) -or
			($operatorElement.GetAttribute('ForceSeek') -in @('1', 'true')) -or
			($operatorElement.GetAttribute('ForceScan') -in @('1', 'true'))
		foreach ($object in @($operatorElement.SelectNodes('p:Object', $ns))) {
			$database = Get-IaColUnquotedName $object.GetAttribute('Database')
			if ([string]::IsNullOrEmpty($database)) {
				$database = $DefaultDatabase
			}
			$schema = Get-IaColUnquotedName $object.GetAttribute('Schema')
			$table = Get-IaColUnquotedName $object.GetAttribute('Table')
			if (Test-IaColPlanObjectSkipped -Database $database -Schema $schema -Table $table) {
				continue
			}
			if ([string]::IsNullOrEmpty($schema)) {
				$schema = 'dbo'
			}
			$index = Get-IaColUnquotedName $object.GetAttribute('Index')
			if ($null -eq $index) {
				$index = ''
			}
			$indexKind = $object.GetAttribute('IndexKind')
			$storage = $object.GetAttribute('Storage')
			if ([string]::IsNullOrEmpty($storage)) {
				$storage = $operatorElement.GetAttribute('Storage')
			}
			if ($storage -eq 'ColumnStore' -and $operation -ne 'Update') {
				$columnstoreOps++
				if ($operatorElement.SelectSingleNode('p:Predicate', $ns)) {
					$columnstoreWithPredicate++
				}
			}
			if ($operation -eq 'Scan' -and $null -eq $seekPredicates) {
				$wholeTable = ($operatorElement.LocalName -eq 'TableScan') -or ($index -eq '') -or
					($indexKind -in @('Clustered', 'ViewClustered', 'Heap'))
				if ($wholeTable) {
					$result.scansWholeTable = $true
				}
			}
			$key = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $database, $schema, $table, $index, $operation, $executionMode)
			if ($seenOperations.Add($key)) {
				$result.indexOperations.Add([ordered]@{
						database = $database
						schema = $schema
						table = $table
						index = $index
						operation = $operation
						executionMode = $executionMode
						isHinted = [bool]$isHinted
					})
			}
		}
		if ($operation -in @('Seek', 'Scan') -and $seekPredicates) {
			foreach ($seekKeys in @($seekPredicates.SelectNodes('.//p:SeekKeys', $ns))) {
				foreach ($part in @($seekKeys.SelectNodes('p:Prefix|p:StartRange|p:EndRange', $ns))) {
					$expressions = $part.SelectSingleNode('p:RangeExpressions', $ns)
					$joinKey = (Get-IaColPlanColumnRefs -Node $expressions -Ns $ns).Count -gt 0
					if ($joinKey) {
						continue
					}
					$operator = if ($part.LocalName -eq 'EndRange') { 'Range' } elseif ($part.GetAttribute('ScanType') -eq 'EQ') { 'Eq' } else { 'Range' }
					foreach ($columnRef in (Get-IaColPlanColumnRefs -Node $part -Ns $ns -XPath 'p:RangeColumns/p:ColumnReference[@Table]')) {
						Add-IaColPlanPredicate -List $result.predicates -Seen $seenPredicates -ColumnRef $columnRef -Operator $operator -DefaultDatabase $DefaultDatabase
					}
				}
			}
		}
	}
	foreach ($compare in @($document.SelectNodes('//p:Predicate//p:Compare', $ns))) {
		$sides = @($compare.SelectNodes('p:ScalarOperator', $ns))
		if ($sides.Count -ne 2) {
			continue
		}
		$left = Get-IaColPlanColumnRefs -Node $sides[0] -Ns $ns
		$right = Get-IaColPlanColumnRefs -Node $sides[1] -Ns $ns
		if (($left.Count -gt 0) -eq ($right.Count -gt 0)) {
			continue
		}
		$columnRefs = if ($left.Count -gt 0) { $left } else { $right }
		$operator = switch ($compare.GetAttribute('CompareOp')) {
			{ $_ -in @('EQ', 'IS') } { 'Eq'; break }
			{ $_ -in @('LT', 'LE', 'GT', 'GE') } { 'Range'; break }
			default { 'Other' }
		}
		foreach ($columnRef in $columnRefs) {
			Add-IaColPlanPredicate -List $result.predicates -Seen $seenPredicates -ColumnRef $columnRef -Operator $operator -DefaultDatabase $DefaultDatabase
		}
	}
	foreach ($intrinsic in @($document.SelectNodes("//p:Predicate//p:Intrinsic[translate(@FunctionName, 'LIKE', 'like') = 'like']", $ns))) {
		$first = $intrinsic.SelectSingleNode('p:ScalarOperator', $ns)
		foreach ($columnRef in (Get-IaColPlanColumnRefs -Node $first -Ns $ns)) {
			Add-IaColPlanPredicate -List $result.predicates -Seen $seenPredicates -ColumnRef $columnRef -Operator 'Like' -DefaultDatabase $DefaultDatabase
		}
	}
	if ($document.SelectSingleNode('//p:PlanAffectingConvert', $ns) -or
		$document.SelectSingleNode("//p:Convert[@Implicit='1' or @Implicit='true'][.//p:ColumnReference[@Table]]", $ns)) {
		$result.hasImplicitConversion = $true
	}
	foreach ($group in @($document.SelectNodes('//p:MissingIndexes/p:MissingIndexGroup', $ns))) {
		$impact = ConvertTo-IaColDouble $group.GetAttribute('Impact') -Digits 2
		foreach ($missing in @($group.SelectNodes('p:MissingIndex', $ns))) {
			$columns = @{ EQUALITY = @(); INEQUALITY = @(); INCLUDE = @() }
			foreach ($columnGroup in @($missing.SelectNodes('p:ColumnGroup', $ns))) {
				$usage = $columnGroup.GetAttribute('Usage')
				if ($columns.ContainsKey($usage)) {
					$columns[$usage] = @($columnGroup.SelectNodes('p:Column', $ns) | ForEach-Object { Get-IaColUnquotedName $_.GetAttribute('Name') })
				}
			}
			$schema = Get-IaColUnquotedName $missing.GetAttribute('Schema')
			$result.missingIndexes.Add([ordered]@{
					schema = $(if ($schema) { $schema } else { 'dbo' })
					table = Get-IaColUnquotedName $missing.GetAttribute('Table')
					equalityColumns = @($columns.EQUALITY)
					inequalityColumns = @($columns.INEQUALITY)
					includedColumns = @($columns.INCLUDE)
					impact = $impact
				})
		}
	}
	if ($partitionedOps -gt 0) {
		$result.partitionElimination = if ($partitionSeeks -gt 0) { 'Yes' } else { 'No' }
	}
	if ($columnstoreOps -gt 0) {
		$result.columnstoreSegmentElimination = if ($columnstoreWithPredicate -gt 0) { 'Unknown' } else { 'No' }
	}
	return $result
}
