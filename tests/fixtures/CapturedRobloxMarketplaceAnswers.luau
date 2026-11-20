-- Real engine answers, captured in Roblox Studio 0.748 on 2026-11-19 on the server of a playtest of
-- the unpublished Place1, for the seven development-sample items of data/styling-item-pool.csv
-- (AVATAR_ITEM_DETAILS_BY_KIND_AND_ID) and for three items that are NOT on sale in the shop
-- (OFF_SALE_AVATAR_ITEM_DETAILS_BY_ASSET_ID). Only the fields the converter reads, plus Owned and
-- (off-sale items) LowestPrice and IsOffSale, are kept; the engine answers carry more
-- (Description, CreatorName, ProductId, FavoriteCount, ...). These tables are the raw record.
--   AvatarEditorService:GetItemDetailsAsync(id, Enum.AvatarItemType.Asset | .Bundle)
--   AssetService:GetBundleDetailsAsync(98186475028072)
-- PriceStatus, listed in the documented response format, was absent from every answer.

local CapturedRobloxMarketplaceAnswers = {}

CapturedRobloxMarketplaceAnswers.AVATAR_ITEM_DETAILS_BY_KIND_AND_ID = {
	Asset = {
		[7259123616] = {
			Id = 7259123616,
			ItemType = "Asset",
			Name = "Black Messy Hairstyle",
			Price = 65,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "HairAccessory",
			Owned = false,
		},
		[9122110415] = {
			Id = 9122110415,
			ItemType = "Asset",
			Name = "Off-Shoulder Jacket White",
			Price = 70,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "JacketAccessory",
			Owned = false,
		},
		[9438759973] = {
			Id = 9438759973,
			ItemType = "Asset",
			Name = "Adorable Pink Princess Gown",
			Price = 120,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "DressSkirtAccessory",
			Owned = false,
		},
		[4378579302] = {
			Id = 4378579302,
			ItemType = "Asset",
			Name = "Black Turtle Neck",
			Price = 55,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "NeckAccessory",
			Owned = false,
		},
		[11884330] = {
			Id = 11884330,
			ItemType = "Asset",
			Name = "Nerd Glasses",
			Price = 95,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "FaceAccessory",
			Owned = false,
		},
		[106390919006817] = {
			Id = 106390919006817,
			ItemType = "Asset",
			Name = "Korean Lipgloss in Soft Cherry",
			Price = 30,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			AssetType = "LipMakeup",
			Owned = false,
		},
	},
	Bundle = {
		[98186475028072] = {
			Id = 98186475028072,
			ItemType = "Bundle",
			Name = "Y2K Fur Boots",
			Price = 60,
			IsPurchasable = true,
			SaleLocationType = "ShopAndAllExperiences",
			ItemRestrictions = {},
			Owned = false,
		},
	},
}

-- Off-sale items, same capture. ItemRestrictions {} was written as {} by the engine; PriceStatus
-- and IsOffSale are absent (nil) on every on-sale answer above.
CapturedRobloxMarketplaceAnswers.OFF_SALE_AVATAR_ITEM_DETAILS_BY_ASSET_ID = {
	-- Off sale, not a limited: the only answer that had IsPurchasable = false.
	[48474294] = {
		Id = 48474294,
		ItemType = "Asset",
		Name = "ROBLOX Girl - Hair",
		Price = 0,
		IsPurchasable = false,
		PriceStatus = "Off Sale",
		SaleLocationType = "ShopAndAllExperiences",
		ItemRestrictions = {},
		AssetType = "HairAccessory",
		Owned = false,
		LowestPrice = 0,
		IsOffSale = true,
	},
	-- Off-sale Roblox Limited, only resold: IsPurchasable true, Price the old shop price.
	[1029025] = {
		Id = 1029025,
		ItemType = "Asset",
		Name = "The Classic ROBLOX Fedora",
		Price = 900,
		IsPurchasable = true,
		SaleLocationType = "ShopOnly",
		ItemRestrictions = { "Limited" },
		AssetType = "Hat",
		Owned = false,
		LowestPrice = 449999,
		IsOffSale = true,
	},
	[21070012] = {
		Id = 21070012,
		ItemType = "Asset",
		Name = "Dominus Empyreus",
		Price = 13337,
		IsPurchasable = true,
		SaleLocationType = "ShopOnly",
		ItemRestrictions = { "LimitedUnique" },
		AssetType = "Hat",
		Owned = false,
		LowestPrice = 618033988,
		IsOffSale = true,
	},
}

CapturedRobloxMarketplaceAnswers.BUNDLE_DETAILS_BY_BUNDLE_ID = {
	[98186475028072] = {
		Id = 98186475028072,
		Name = "Y2K Fur Boots",
		BundleType = "Shoes",
		Items = {
			{
				Id = 84885203198436,
				Type = "Asset",
				AssetType = "LeftShoeAccessory",
				Name = "Y2K Fur Boots - Left Shoe Accessory",
			},
			{
				Id = 90774383444285,
				Type = "Asset",
				AssetType = "RightShoeAccessory",
				Name = "Y2K Fur Boots - Right Shoe Accessory",
			},
			{ Id = 2588879495818671, Type = "UserOutfit", Name = "Y2K Fur Boots" },
		},
	},
}

-- The error text the engine raised for item details of a non-existent asset (id 1).
CapturedRobloxMarketplaceAnswers.ITEM_DETAILS_HTTP_400_ERROR_MESSAGE =
	"AvatarEditorService::getItemDetails failed: HTTP request failed with status code: 400"

-- Returns a fresh deep copy, so a test that changes an answer cannot affect another test.
function CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer)
	local answerCopy = {}
	for fieldName, fieldValue in capturedAnswer do
		answerCopy[fieldName] = if type(fieldValue) == "table"
			then CapturedRobloxMarketplaceAnswers.copyAnswer(fieldValue)
			else fieldValue
	end
	return answerCopy
end

return CapturedRobloxMarketplaceAnswers
