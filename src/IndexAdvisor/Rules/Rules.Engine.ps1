# Rules engine — детермінований попередній аналіз без LLM (розділ 4.3 ТЗ; CONTRACTS.md, розділи 3.5, 5.2).

function Test-IaExpensiveIndex {
	<# «Дорогий» індекс (розділ 4.4): помітні lock/latch-очікування або updates значно переважають читання, і читань мало.
	   Index — індекс зі snapshot (для AG — з usage й operational, підсумованими по репліках). Повертає @{ isExpensive; reasons = @() }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Index,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$relaxed = $Config.rules.relaxed
	$usage = $Index['usage']
	$operational = $Index['operational']
	$reads = Get-IaRuleReads -Usage $usage
	if ($null -eq $reads) {
		# Без статистики використання «читань мало» не встановити — консервативно не «дорогий».
		return [ordered]@{ isExpensive = $false; reasons = @() }
	}
	$updates = [long]$usage['userUpdates']
	$reasons = [System.Collections.Generic.List[string]]::new()
	if ($operational -is [System.Collections.IDictionary]) {
		$lockMs = [long]$operational['rowLockWaitMs'] + [long]$operational['pageLockWaitMs']
		if ($lockMs -gt 0 -and $lockMs -ge [long]$relaxed.minLockWaitMs) {
			$reasons.Add("очікування на блокуваннях $lockMs мс (поріг $($relaxed.minLockWaitMs) мс)")
		}
		$latchMs = [long]$operational['pageLatchWaitMs'] + [long]$operational['pageIoLatchWaitMs']
		if ($latchMs -gt 0 -and $latchMs -ge [long]$relaxed.minLatchWaitMs) {
			$reasons.Add("очікування на латчах $latchMs мс (поріг $($relaxed.minLatchWaitMs) мс)")
		}
	}
	$ratio = [double]$relaxed.minWriteToReadRatio
	if ($updates -gt 0 -and $updates -ge [long]$Config.rules.writeOnlyMinUpdates -and $updates -ge $ratio * [math]::Max([long]1, $reads)) {
		$reasons.Add("оновлень $updates значно більше за читання $reads (співвідношення не менше $(Format-IaRuleNumber $ratio))")
	}
	if ($reasons.Count -eq 0 -or $reads -gt [long]$relaxed.maxReads) {
		return [ordered]@{ isExpensive = $false; reasons = @() }
	}
	$reasons.Add("читань мало: $reads (не більше $($relaxed.maxReads))")
	return [ordered]@{ isExpensive = $true; reasons = @($reasons) }
}

function Get-IaRuleIndexBlockers {
	<# Невиконані структурні умови 4.4 для індексу (тексти для знахідок). #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$Index)
	return @(Get-IaRuleStructuralConditions -Logical $Logical -Schema $Schema -Table $Table -Index $Index |
			Where-Object { $_.met -ne $true } | ForEach-Object { '{0}: {1}' -f $_.id, $_.details })
}

function Get-IaRuleIndexSummary {
	<# Коротке визначення індексу для details знахідок. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	return [ordered]@{
		name = [string]$Index['name']
		typeDesc = [string]$Index['typeDesc']
		keyColumns = @(Get-IaRuleKeyColumns -Index $Index | ForEach-Object { if ($_.desc) { "$($_.name) DESC" } else { $_.name } })
		includedColumns = @($Index['includedColumns'] | Where-Object { $_ })
		filterDefinition = $Index['filterDefinition']
		isUnique = [bool]($Index['isUnique'] -or $Index['isUniqueConstraint'])
		isPrimaryKey = [bool]$Index['isPrimaryKey']
	}
}

function Select-IaRuleKeeperIndex {
	<# З групи індексів з однаковими ключами обирає той, що лишається: PK > UNIQUE > кластерний > ширший INCLUDE > більше читань. #>
	param([Parameter(Mandatory)][object[]]$Group, [hashtable]$Aggregated)
	return $Group | Sort-Object -Descending -Property @(
		@{ Expression = { [int][bool]$_['isPrimaryKey'] } }
		@{ Expression = { [int][bool]($_['isUniqueConstraint'] -or $_['isUnique']) } }
		@{ Expression = { [int]($_['typeDesc'] -eq 'CLUSTERED') } }
		@{ Expression = { @($_['includedColumns'] | Where-Object { $_ }).Count } }
		@{ Expression = { $reads = Get-IaRuleReads -Usage $Aggregated[[string]$_['name']]['usage']; if ($null -eq $reads) { -1 } else { $reads } } }
	) | Select-Object -First 1
}

function Invoke-IaRulesEngine {
	<# Детермінований попередній аналіз без LLM: DuplicateIndex, OverlappingIndex, UnusedIndex, WriteOnlyIndex,
	   MissingIndexCandidate (злиті), TooManyIndexes, Fragmentation, ExpensiveIndex. Повертає масив New-IaFinding. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$findings = [System.Collections.Generic.List[object]]::new()
	foreach ($logical in @(Get-IaRuleLogicalDatabases -Snapshot $Snapshot)) {
		foreach ($table in @($logical.primary.database['tables'])) {
			if ($table -isnot [System.Collections.IDictionary]) {
				continue
			}
			$schema = [string]$table['schema']
			$tableName = [string]$table['name']
			$active = @(Get-IaRuleActiveIndexes -Table $table)
			$aggregated = @{}
			foreach ($index in $active) {
				$aggregated[[string]$index['name']] = Get-IaRuleAggregatedIndex -Logical $logical -Schema $schema -Table $tableName -Index $index
			}
			$blockerCache = @{}
			$getBlockers = {
				param([string]$Name)
				if (-not $blockerCache.ContainsKey($Name)) {
					$blockerCache[$Name] = @(Get-IaRuleIndexBlockers -Logical $logical -Schema $schema -Table $tableName -Index $Name)
				}
				return , $blockerCache[$Name]
			}
			$newTarget = {
				param([string]$Name)
				return New-IaTarget -Server $logical.server -Database $logical.database -Schema $schema -Table $tableName -Index $Name
			}
			$tableLabel = "[$schema].[$tableName]"

			# DuplicateIndex: однакові ключі в тому самому порядку й напрямку, однаковий фільтр (рядкові індекси).
			$rowstore = @($active | Where-Object { Test-IaRuleRowstore -Index $_ })
			$groups = [ordered]@{}
			foreach ($index in $rowstore) {
				$signature = (ConvertTo-IaRuleFilterKey $index['filterDefinition']) + '|' + ((Get-IaRuleKeyColumns -Index $index | ForEach-Object { '{0}:{1}' -f $_.name.ToLowerInvariant(), [int]$_.desc }) -join ',')
				if (-not $groups.Contains($signature)) {
					$groups[$signature] = [System.Collections.Generic.List[object]]::new()
				}
				$groups[$signature].Add($index)
			}
			$duplicateNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
			foreach ($group in $groups.Values) {
				if ($group.Count -lt 2) {
					continue
				}
				$keeper = Select-IaRuleKeeperIndex -Group $group.ToArray() -Aggregated $aggregated
				foreach ($other in $group) {
					if ([object]::ReferenceEquals($other, $keeper)) {
						continue
					}
					$name = [string]$other['name']
					[void]$duplicateNames.Add($name)
					$keeperClustered = $keeper['typeDesc'] -eq 'CLUSTERED'
					$missingIncludes = @($other['includedColumns'] | Where-Object { $_ -and -not $keeperClustered -and @($keeper['includedColumns']) -notcontains $_ })
					$covered = $missingIncludes.Count -eq 0
					$isConstraint = [bool]($other['isPrimaryKey'] -or $other['isUniqueConstraint'] -or ($other['isUnique'] -and -not ($keeper['isUnique'] -or $keeper['isUniqueConstraint'])))
					$blockers = & $getBlockers $name
					$action = if ($isConstraint) { 'None' } elseif ($covered) { 'DropIndex' } else { 'AlterIndex' }
					$severity = if ($covered -and -not $keeperClustered) { 'High' } else { 'Medium' }
					$message = "Індекс [$name] на $tableLabel дублює ключі індексу [$($keeper['name'])]"
					if (-not $covered) {
						$message += "; INCLUDE ($($missingIncludes -join ', ')) треба перенести в [$($keeper['name'])] перед видаленням"
					}
					if ($blockers.Count) {
						$message += '. Видалення обмежене: ' + ($blockers -join '; ')
					}
					$findings.Add((New-IaFinding -RuleId 'DuplicateIndex' -Severity $severity -Target (& $newTarget $name) -Message $message -RelatedIndexes @([string]$keeper['name']) -SuggestedAction $action -Details ([ordered]@{
									index = Get-IaRuleIndexSummary -Index $other
									keeper = Get-IaRuleIndexSummary -Index $keeper
									includesCovered = $covered
									missingIncludes = @($missingIncludes)
									blockers = @($blockers)
								})))
				}
			}

			# OverlappingIndex: ключі індексу — лівий префікс ключів іншого (той самий фільтр).
			foreach ($index in $rowstore) {
				$name = [string]$index['name']
				if ($index['typeDesc'] -eq 'CLUSTERED' -or $index['isPrimaryKey'] -or $index['isUnique'] -or $index['isUniqueConstraint'] -or $duplicateNames.Contains($name)) {
					continue
				}
				$keys = @(Get-IaRuleKeyColumns -Index $index)
				$filterKey = ConvertTo-IaRuleFilterKey $index['filterDefinition']
				$covering = [System.Collections.Generic.List[object]]::new()
				foreach ($other in $rowstore) {
					if ([object]::ReferenceEquals($other, $index) -or (ConvertTo-IaRuleFilterKey $other['filterDefinition']) -ne $filterKey) {
						continue
					}
					$otherKeys = @(Get-IaRuleKeyColumns -Index $other)
					if (Test-IaRuleKeyPrefix -Short $keys -Long $otherKeys -Strict) {
						$available = @($otherKeys | ForEach-Object { $_.name }) + @($other['includedColumns'] | Where-Object { $_ })
						$fully = $other['typeDesc'] -eq 'CLUSTERED' -or (Test-IaRuleSubset -Subset @($index['includedColumns']) -Superset $available)
						$covering.Add([ordered]@{ name = [string]$other['name']; fullyCovers = [bool]$fully })
					}
				}
				if ($covering.Count -eq 0) {
					continue
				}
				$fullyCovered = @($covering | Where-Object { $_.fullyCovers }).Count -gt 0
				$blockers = & $getBlockers $name
				$related = @($covering | ForEach-Object { $_.name })
				$message = "Ключі індексу [$name] на $tableLabel є лівим префіксом ключів: $($related -join ', ')"
				if (-not $fullyCovered) {
					$message += '; INCLUDE-колонки покрито не повністю'
				}
				if ($blockers.Count) {
					$message += '. Видалення обмежене: ' + ($blockers -join '; ')
				}
				$findings.Add((New-IaFinding -RuleId 'OverlappingIndex' -Severity $(if ($fullyCovered) { 'Medium' } else { 'Low' }) -Target (& $newTarget $name) -Message $message -RelatedIndexes $related -SuggestedAction $(if ($fullyCovered) { 'DropIndex' } else { 'AlterIndex' }) -Details ([ordered]@{
								index = Get-IaRuleIndexSummary -Index $index
								coveringIndexes = @($covering)
								blockers = @($blockers)
							})))
			}

			# UnusedIndex, WriteOnlyIndex, ExpensiveIndex: за статистикою, підсумованою по всіх репліках AG, і планами Query Store.
			foreach ($index in $active) {
				if (Test-IaRuleClusteredIndex -Index $index) {
					continue
				}
				$name = [string]$index['name']
				$aggregate = $aggregated[$name]
				$usage = $aggregate['usage']
				if ($usage -isnot [System.Collections.IDictionary]) {
					continue
				}
				$reads = Get-IaRuleReads -Usage $usage
				$updates = [long]$usage['userUpdates']
				$isConstraint = [bool]($index['isPrimaryKey'] -or $index['isUniqueConstraint'] -or $index['isUnique'])
				$coverage = $aggregate['replicaCoverage']
				$coverageNote = if (@($coverage.withoutUsage).Count) { " Статистики використання немає на репліках: $(@($coverage.withoutUsage) -join ', ')." } else { '' }
				$details = [ordered]@{
					index = Get-IaRuleIndexSummary -Index $index
					userSeeks = [long]$usage['userSeeks']
					userScans = [long]$usage['userScans']
					userLookups = [long]$usage['userLookups']
					userUpdates = $updates
					replicas = @($coverage.replicas)
					replicasWithoutUsage = @($coverage.withoutUsage)
					queryStore = $null
					blockers = @()
				}
				if ($reads -eq 0) {
					$qsCondition = Get-IaRuleQueryStoreCondition -Logical $logical -Schema $schema -Table $tableName -Index $name
					$details.queryStore = $qsCondition.details
					if ($qsCondition.met -ne $false) {
						$details.blockers = & $getBlockers $name
						$constraintNote = if ($isConstraint) { ' Індекс забезпечує унікальність (PK/UNIQUE), видаляти його не можна.' } else { '' }
						if ($updates -ge [long]$Config.rules.writeOnlyMinUpdates) {
							$message = "Індекс [$name] на $tableLabel лише оновлюється: $updates оновлень, жодного читання на всіх репліках.$constraintNote$coverageNote"
							$findings.Add((New-IaFinding -RuleId 'WriteOnlyIndex' -Severity $(if ($isConstraint) { 'Info' } else { 'Medium' }) -Target (& $newTarget $name) -Message $message -SuggestedAction $(if ($isConstraint) { 'None' } else { 'DropIndex' }) -Details $details))
						}
						else {
							$message = "Індекс [$name] на $tableLabel не використовується: жодного читання на всіх репліках.$constraintNote$coverageNote"
							$findings.Add((New-IaFinding -RuleId 'UnusedIndex' -Severity $(if ($isConstraint) { 'Info' } else { 'Low' }) -Target (& $newTarget $name) -Message $message -SuggestedAction $(if ($isConstraint) { 'None' } else { 'DropIndex' }) -Details $details))
						}
					}
				}
				if (-not $index['isPrimaryKey']) {
					$expensive = Test-IaExpensiveIndex -Index $aggregate -Config $Config
					if ($expensive.isExpensive) {
						$expensiveDetails = [ordered]@{
							index = Get-IaRuleIndexSummary -Index $index
							reasons = @($expensive.reasons)
							reads = $reads
							userUpdates = $updates
							operational = $aggregate['operational']
							relaxedRulesApply = [bool]$Config.rules.relaxed.enabled
							blockers = @(& $getBlockers $name)
						}
						$message = "Індекс [$name] на $tableLabel створює помітне навантаження за малої кількості читань: $($expensive.reasons -join '; ')"
						$findings.Add((New-IaFinding -RuleId 'ExpensiveIndex' -Severity $(if ($isConstraint) { 'Info' } else { 'Medium' }) -Target (& $newTarget $name) -Message $message -SuggestedAction $(if ($isConstraint) { 'None' } else { 'DropIndex' }) -Details $expensiveDetails))
					}
				}
			}

			# TooManyIndexes.
			$maxIndexes = [int]$Config.rules.maxIndexesPerTable
			if ($active.Count -gt $maxIndexes) {
				$findings.Add((New-IaFinding -RuleId 'TooManyIndexes' -Severity 'Medium' -Target (& $newTarget $null) -Message "На $tableLabel $($active.Count) індексів (поріг rules.maxIndexesPerTable = $maxIndexes)" -RelatedIndexes @($active | ForEach-Object { [string]$_['name'] }) -Details ([ordered]@{
								indexCount = $active.Count
								threshold = $maxIndexes
								disabledCount = @(Get-IaRuleActiveIndexes -Table $table -IncludeDisabled).Count - $active.Count
							})))
			}

			# Fragmentation (рядкові індекси, LIMITED).
			$fragmentation = $Config.rules.fragmentation
			foreach ($index in $rowstore) {
				$name = [string]$index['name']
				$physical = $null
				foreach ($copy in @(Get-IaRuleIndexReplicas -Logical $logical -Schema $schema -Table $tableName -Index $name)) {
					if ($copy.index -and $copy.index['physical'] -is [System.Collections.IDictionary] -and -not $copy.index['physical']['skipped'] -and $null -ne $copy.index['physical']['avgFragmentationPercent']) {
						$physical = $copy.index['physical']
						break
					}
				}
				if ($null -eq $physical -or [long]$physical['pageCount'] -lt [long]$fragmentation.minPageCount) {
					continue
				}
				$percent = [double]$physical['avgFragmentationPercent']
				if ($percent -lt [double]$fragmentation.reorganizePercent) {
					continue
				}
				$operation = if ($percent -ge [double]$fragmentation.rebuildPercent) { 'REBUILD' } else { 'REORGANIZE' }
				$message = "Фрагментація індексу [$name] на $tableLabel $(Format-IaRuleNumber $percent)% ($($physical['pageCount']) сторінок): рекомендовано $operation"
				$findings.Add((New-IaFinding -RuleId 'Fragmentation' -Severity $(if ($operation -eq 'REBUILD') { 'Medium' } else { 'Low' }) -Target (& $newTarget $name) -Message $message -SuggestedAction 'AlterIndex' -Details ([ordered]@{
								avgFragmentationPercent = $percent
								pageCount = [long]$physical['pageCount']
								recommendedOperation = $operation
								reorganizePercent = [double]$fragmentation.reorganizePercent
								rebuildPercent = [double]$fragmentation.rebuildPercent
							})))
			}
		}
	}

	# MissingIndexCandidate: злиті кандидати missing index (DMV і плани Query Store).
	foreach ($candidate in @(Merge-IaMissingIndexes -Snapshot $Snapshot -Config $Config)) {
		$seeks = [long]$candidate.userSeeks + [long]$candidate.userScans
		$impact = [double]$candidate.avgUserImpact
		$severity = if ($impact -ge 80 -and $seeks -ge 1000) { 'High' } elseif ($impact -ge 50) { 'Medium' } else { 'Low' }
		$target = $candidate.target
		$message = "Кандидат на індекс [$($target.index)] на [$($target.schema)].[$($target.table)] ($($candidate.keyColumns -join ', '))"
		if (@($candidate.includedColumns).Count) {
			$message += " INCLUDE ($($candidate.includedColumns -join ', '))"
		}
		$message += ": злито $(@($candidate.sourceIndexHandles).Count + @($candidate.queryIds).Count) пропозицій missing index, очікуваний вплив $(Format-IaRuleNumber $impact)%"
		$findings.Add((New-IaFinding -RuleId 'MissingIndexCandidate' -Severity $severity -Target $target -Message $message -SuggestedAction 'CreateIndex' -Details ([ordered]@{
						keyColumns = @($candidate.keyColumns)
						includedColumns = @($candidate.includedColumns)
						equalityColumns = @($candidate.equalityColumns)
						inequalityColumns = @($candidate.inequalityColumns)
						sourceIndexHandles = @($candidate.sourceIndexHandles)
						queryIds = @($candidate.queryIds)
						userSeeks = [long]$candidate.userSeeks
						userScans = [long]$candidate.userScans
						avgUserImpact = $impact
						avgTotalUserCost = $candidate.avgTotalUserCost
						estimate = $candidate.estimate
					})))
	}
	return $findings.ToArray()
}
