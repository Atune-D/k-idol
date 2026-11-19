-- Turns values into readable text for test failure messages, and compares tables by content.
-- Used by UnitTestExpectations; kept separate so the matchers stay short.

local TestValueDescriber = {}

local MAXIMUM_DESCRIBED_TABLE_DEPTH = 4

local function describeTableKey(tableKey: any): string
	if type(tableKey) == "string" and string.match(tableKey, "^[%a_][%w_]*$") then
		return tableKey
	end
	return "[" .. TestValueDescriber.describeValue(tableKey) .. "]"
end

local function collectSortedTableKeys(describedTable: { [any]: any }): { any }
	local tableKeys = {}
	for tableKey in describedTable do
		table.insert(tableKeys, tableKey)
	end
	table.sort(tableKeys, function(leftKey, rightKey)
		local leftKeyType, rightKeyType = type(leftKey), type(rightKey)
		if leftKeyType ~= rightKeyType then
			return leftKeyType < rightKeyType
		end
		if leftKeyType == "number" or leftKeyType == "string" then
			return leftKey < rightKey
		end
		return tostring(leftKey) < tostring(rightKey)
	end)
	return tableKeys
end

local function describeValueAtDepth(describedValue: any, currentDepth: number): string
	local describedValueType = type(describedValue)
	if describedValueType == "string" then
		return string.format("%q", describedValue)
	end
	if describedValueType ~= "table" then
		return tostring(describedValue)
	end
	if currentDepth >= MAXIMUM_DESCRIBED_TABLE_DEPTH then
		return "{...}"
	end

	local describedEntries = {}
	for _, tableKey in collectSortedTableKeys(describedValue) do
		local describedEntryValue = describeValueAtDepth(describedValue[tableKey], currentDepth + 1)
		table.insert(describedEntries, describeTableKey(tableKey) .. " = " .. describedEntryValue)
	end
	if #describedEntries == 0 then
		return "{}"
	end
	return "{ " .. table.concat(describedEntries, ", ") .. " }"
end

function TestValueDescriber.describeValue(describedValue: any): string
	return describeValueAtDepth(describedValue, 0)
end

-- Two values are deeply equal when they are primitively equal, or when both are tables
-- holding deeply equal values under exactly the same keys. Metatables are ignored.
function TestValueDescriber.areValuesDeeplyEqual(leftValue: any, rightValue: any): boolean
	if leftValue == rightValue then
		return true
	end
	if type(leftValue) ~= "table" or type(rightValue) ~= "table" then
		return false
	end
	for tableKey, leftEntryValue in leftValue do
		if not TestValueDescriber.areValuesDeeplyEqual(leftEntryValue, rightValue[tableKey]) then
			return false
		end
	end
	for tableKey in rightValue do
		if leftValue[tableKey] == nil then
			return false
		end
	end
	return true
end

return TestValueDescriber
