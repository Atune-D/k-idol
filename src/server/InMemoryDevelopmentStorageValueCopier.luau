-- InMemoryDevelopmentStorageValueCopier: the deep copy the two in-memory development storages
-- use for every value going in or out, so nothing a caller does to a table it handed in or got
-- back can change what the storage holds (the same isolation a real data store gives, where
-- every value travels as a serialized copy).
--
-- It refuses (returns nil plus a reason) anything a data store could not hold either: a function,
-- a thread, a userdata, a table with a metatable, a table reached twice (a cycle or a shared
-- table), a key that is not a string or a number, NaN, or nesting deeper than
-- MAXIMUM_NESTING_DEPTH. Refusing makes the development storage report a failed write instead of
-- quietly accepting a save the real store would reject.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   InMemoryDevelopmentStorageValueCopier.MAXIMUM_NESTING_DEPTH = 16
--   InMemoryDevelopmentStorageValueCopier.copyStorableValue(originalValue) -> (copiedValue?, refusalReason: string?)
--     For a storable value: (a deep copy, nil). For nil: (nil, nil). Otherwise (nil, reason).

local InMemoryDevelopmentStorageValueCopier = {}

InMemoryDevelopmentStorageValueCopier.MAXIMUM_NESTING_DEPTH = 16

local function copyValueOrRaise(originalValue: any, visitedTables: { [any]: boolean }, nestingDepth: number): any
	local valueType = type(originalValue)
	if valueType == "string" or valueType == "boolean" or valueType == "nil" then
		return originalValue
	end
	if valueType == "number" then
		if originalValue ~= originalValue then
			error("NaN cannot be stored", 0)
		end
		return originalValue
	end
	if valueType ~= "table" then
		error(string.format("a %s cannot be stored", valueType), 0)
	end
	if getmetatable(originalValue) ~= nil then
		error("a table with a metatable cannot be stored", 0)
	end
	if visitedTables[originalValue] then
		error("a table reached twice (a cycle or a shared table) cannot be stored", 0)
	end
	if nestingDepth > InMemoryDevelopmentStorageValueCopier.MAXIMUM_NESTING_DEPTH then
		error("tables nested deeper than the limit cannot be stored", 0)
	end
	visitedTables[originalValue] = true
	local copiedTable = {}
	for originalKey, originalFieldValue in originalValue do
		local keyType = type(originalKey)
		if keyType ~= "string" and keyType ~= "number" then
			error(string.format("a table key of type %s cannot be stored", keyType), 0)
		end
		copiedTable[originalKey] = copyValueOrRaise(originalFieldValue, visitedTables, nestingDepth + 1)
	end
	return copiedTable
end

function InMemoryDevelopmentStorageValueCopier.copyStorableValue(originalValue: any): (any, string?)
	local didCopy, copiedValueOrReason = pcall(copyValueOrRaise, originalValue, {}, 1)
	if not didCopy then
		return nil, tostring(copiedValueOrReason)
	end
	return copiedValueOrReason, nil
end

return table.freeze(InMemoryDevelopmentStorageValueCopier)
