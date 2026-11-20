-- The plan-to-HumanoidDescription writing has ONE home, used by the server's PlayerCharacterDresser
-- and the device's wardrobe preview. Checked on a stand-in description that records every call.

local fs = require("@lune/fs")

local UnitTestFramework = require("../Support/UnitTestFramework")
local CharacterAppearancePlanDescriptionWriter = require("../../src/shared/CharacterAppearancePlanDescriptionWriter")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- The file's code lines (lines that are only a comment are left out, so headers may name things).
local function readCodeWithoutCommentLines(sourcePath: string): string
	local codeLines = {}
	for _, sourceLine in string.split(fs.readFile(sourcePath), "\n") do
		if not string.match(sourceLine, "^%s*%-%-") then
			table.insert(codeLines, sourceLine)
		end
	end
	return table.concat(codeLines, "\n")
end

local function createStandInEngineTypes()
	local createdInstances = {}
	return {
		accessoryTypeByName = { Hair = "ENUM_Hair", Jacket = "ENUM_Jacket", Shoes = "ENUM_Shoes" },
		makeupTypeByName = { Lip = "ENUM_Lip", Eye = "ENUM_Eye" },
		createInstance = function(className)
			local instance = { ClassName = className }
			table.insert(createdInstances, instance)
			return instance
		end,
		createdInstances = createdInstances,
	}
end

local function createStandInDescription(existingChildren, existingAccessories)
	local description = { calls = {}, children = existingChildren or {}, destroyed = {} }
	function description:GetAccessories(includeRigid)
		table.insert(self.calls, { "GetAccessories", includeRigid })
		return existingAccessories or {}
	end
	function description:SetAccessories(entries, includeRigid)
		table.insert(self.calls, { "SetAccessories", entries, includeRigid })
	end
	function description:GetChildren()
		return self.children
	end
	return description
end

local function createStandInChild(className, destroyedList)
	local child = { ClassName = className }
	function child:IsA(name)
		return name == className
	end
	function child:Destroy()
		table.insert(destroyedList, className)
	end
	return child
end

local PLAN = {
	accessoryEntries = {
		{ accessoryTypeName = "Hair", assetId = 11, isLayered = false },
		{ accessoryTypeName = "Jacket", assetId = 22, isLayered = true, layeredClothingOrder = 7 },
	},
	classicClothingAssetIdByDescriptionPropertyName = { Shirt = 0, Pants = 0, GraphicTShirt = 33 },
	makeupEntries = { { assetId = 44, makeupTypeName = "Lip", makeupOrder = 2 } },
}

describe("CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription", function()
	it("replaces every accessory, rigid ones without Order and layered ones with it", function()
		local engineTypes = createStandInEngineTypes()
		local description = createStandInDescription()
		CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(description, PLAN, engineTypes)
		expect(description.calls).toEqual({
			{
				"SetAccessories",
				{
					{ AccessoryType = "ENUM_Hair", AssetId = 11, IsLayered = false },
					{ AccessoryType = "ENUM_Jacket", AssetId = 22, IsLayered = true, Order = 7 },
				},
				true,
			},
		})
	end)

	it("sets the classic clothing from the plan, 0 included", function()
		local description = createStandInDescription()
		description.Shirt, description.Pants = 5, 6
		CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(
			description,
			PLAN,
			createStandInEngineTypes()
		)
		expect({ description.Shirt, description.Pants, description.GraphicTShirt }).toEqual({ 0, 0, 33 })
	end)

	it("destroys only the old makeup and adds one MakeupDescription per planned entry", function()
		local destroyed = {}
		local description = createStandInDescription({
			createStandInChild("MakeupDescription", destroyed),
			createStandInChild("AccessoryDescription", destroyed),
			createStandInChild("MakeupDescription", destroyed),
		})
		local engineTypes = createStandInEngineTypes()
		CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(description, PLAN, engineTypes)
		expect(destroyed).toEqual({ "MakeupDescription", "MakeupDescription" })
		expect(engineTypes.createdInstances).toEqual({
			{ ClassName = "MakeupDescription", AssetId = 44, MakeupType = "ENUM_Lip", Order = 2, Parent = description },
		})
	end)
end)

describe("CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner", function()
	it("reads every accessory, rigid included, in the planner's shape", function()
		local description = createStandInDescription(nil, {
			{ AccessoryType = { Name = "Hair" }, AssetId = 1, IsLayered = false },
			{ AccessoryType = { Name = "Shoes" }, AssetId = 2, IsLayered = true, Order = 4 },
		})
		expect(CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(description)).toEqual({
			{ accessoryTypeName = "Hair", assetId = 1, isLayered = false },
			{ accessoryTypeName = "Shoes", assetId = 2, isLayered = true, layeredClothingOrder = 4 },
		})
		expect(description.calls).toEqual({ { "GetAccessories", true } })
	end)
end)

describe("one home for the writing", function()
	it("is what the server's dresser and the device's preview call; neither writes a plan itself", function()
		for _, sourcePath in
			{ "src/server/PlayerCharacterDresser.luau", "src/client/RobloxWardrobePreviewCharacter.luau" }
		do
			local source = readCodeWithoutCommentLines(sourcePath)
			expect(
				string.find(
					source,
					"CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(",
					1,
					true
				) ~= nil
			).toBe(true)
			expect(
				string.find(source, "CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(", 1, true)
					~= nil
			).toBe(true)
			expect(string.find(source, ":SetAccessories(", 1, true)).toBeNil()
			expect(string.find(source, 'Instance.new("MakeupDescription")', 1, true)).toBeNil()
		end
	end)
end)
