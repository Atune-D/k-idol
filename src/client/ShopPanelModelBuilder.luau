-- ShopPanelModelBuilder (development spec §0.2 "How players spend", §1.7, §2.8): decides what the shop
-- panel of the lobby menu shows, as plain data. Four groups, in this order: Dances, Titles, Nameplate
-- styles, Stage entrance effects; items in catalog order, each with its catalog name and Star Coin
-- price and a preview built from the shared look data (CosmeticPresentationCatalog):
--   * Title: the title text; NameplateStyle: the nameplate look (the view draws the plate with the
--     player's name); StageEntranceEffect: a still preview (StageEntranceEffectPreviewDotPlanner).
--     Dances have no preview here (they are tried in the Dances panel or by joining a dancer).
-- The Dances group lists the dances that are SOLD: those not granted to new players (every player
-- already owns the starter dances, §1.10). With none for sale it says so instead of being empty.
-- Ownership, the equipped item and the balance come ONLY from the latest save snapshot (§2.6, §5.1):
--   * owned: "Owned", or "Equipped" / "Your stage dance" for the equipped one; no Buy button; an owned
--     item that is not equipped offers "Equip" / "Use on stage" (RequestEquipCosmetic /
--     RequestEquipDance). The server has no "unequip" request, so nothing offers one.
--   * not owned: "Buy for N Star Coins" (RequestPurchaseCosmeticWithStarCoins /
--     RequestPurchaseDanceWithStarCoins); when the balance does not cover the price the button is
--     disabled and the row says how many Star Coins are missing (never a silent failure).
--   * before the first snapshot: no Buy or Equip button, and a loading line.
-- Each row explains the latest answer to a buy or equip request for that item (LobbyRequestAnswerTexts).
-- Pure logic: no Roblox-specific interface is used. Catalogs are passed in, so tests use fixtures.
--
-- PUBLIC API
--   ShopPanelModelBuilder.buildShopPanelModel(shopInputs) -> model
--   shopInputs = { lobbySnapshot?, danceCatalogDances, cosmeticCatalog (COSMETIC_KINDS,
--     listCosmeticsOfKind), findCosmeticPresentation(cosmeticId) -> presentation?,
--     outcomeByRemoteChannelName = { [channelName]: outcome? } }
--   model = { loadingText, balanceText, groups = { { groupTitleText, emptyGroupText, itemRows } } }
--   itemRow = { shopItemKind = "Dance" | "Cosmetic", itemId, cosmeticKind?, nameText, priceText,
--     ownershipText, isBuyButtonVisible, isBuyButtonEnabled, buyButtonText, missingStarCoinsText,
--     isEquipButtonVisible, equipButtonText, isOwned, isEquipped, preview?, feedbackText }
--   preview = { previewKind = "Title", titleText } | { previewKind = "NameplateStyle", nameplateStyleLook }
--           | { previewKind = "StageEntranceEffect", entranceEffectPreview }

local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")
local PlayerFacingTexts = require("./PlayerFacingTexts")
local StageEntranceEffectPreviewDotPlanner = require("./StageEntranceEffectPreviewDotPlanner")

local ShopPanelModelBuilder = {}

ShopPanelModelBuilder.LOADING_TEXT = "Loading your Star Coins..."
ShopPanelModelBuilder.NO_DANCES_FOR_SALE_TEXT =
	"No dances for sale yet. New dances are on their way! Your starter dances are in the Dances panel."

local GROUP_TITLE_TEXT_BY_COSMETIC_KIND = table.freeze({
	Title = "Titles",
	NameplateStyle = "Nameplate styles",
	StageEntranceEffect = "Stage entrance effects",
})

local function formatStarCoins(amount: number): string
	return PlayerFacingTexts.formatWholeNumber(amount) .. " Star Coins"
end

local function buildPreview(cosmeticId: string, findCosmeticPresentation)
	local presentation = findCosmeticPresentation(cosmeticId)
	if presentation == nil then
		return nil
	elseif presentation.cosmeticKind == "Title" then
		return { previewKind = "Title", titleText = presentation.titleText }
	elseif presentation.cosmeticKind == "NameplateStyle" then
		return { previewKind = "NameplateStyle", nameplateStyleLook = presentation.nameplateStyleLook }
	end
	return {
		previewKind = "StageEntranceEffect",
		entranceEffectPreview = StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(
			presentation.stageEntranceEffectLook
		),
	}
end

-- itemFacts = { shopItemKind, itemId, nameText, starCoinPrice, isOwned, isEquipped, equippedText,
--   equipButtonText, purchaseOutcome, equipOutcome }
local function buildItemRow(itemFacts, lobbySnapshot)
	local itemRow = {
		shopItemKind = itemFacts.shopItemKind,
		itemId = itemFacts.itemId,
		nameText = itemFacts.nameText,
		priceText = formatStarCoins(itemFacts.starCoinPrice),
		ownershipText = "",
		isBuyButtonVisible = false,
		isBuyButtonEnabled = false,
		buyButtonText = "Buy for " .. formatStarCoins(itemFacts.starCoinPrice),
		missingStarCoinsText = "",
		isEquipButtonVisible = false,
		equipButtonText = itemFacts.equipButtonText,
		isOwned = false,
		isEquipped = false,
		-- The latest tap on this item (buy or equip) is the one explained.
		feedbackText = LobbyRequestAnswerTexts.describeLatestOutcomeForSubject(
			{ itemFacts.purchaseOutcome, itemFacts.equipOutcome },
			itemFacts.itemId
		),
	}
	if lobbySnapshot == nil then
		return itemRow
	end
	if itemFacts.isOwned then
		itemRow.isOwned = true
		itemRow.isEquipped = itemFacts.isEquipped
		itemRow.ownershipText = if itemFacts.isEquipped then itemFacts.equippedText else "Owned"
		itemRow.isEquipButtonVisible = not itemFacts.isEquipped
		return itemRow
	end
	itemRow.ownershipText = "Not owned yet"
	itemRow.isBuyButtonVisible = true
	local missingStarCoins = itemFacts.starCoinPrice - lobbySnapshot.shownStarCoinBalance
	itemRow.isBuyButtonEnabled = missingStarCoins <= 0
	if missingStarCoins > 0 then
		itemRow.missingStarCoinsText = string.format(
			"You need %s more %s.",
			PlayerFacingTexts.formatWholeNumber(missingStarCoins),
			if missingStarCoins == 1 then "Star Coin" else "Star Coins"
		)
	end
	return itemRow
end

local function buildDanceGroup(shopInputs)
	local lobbySnapshot = shopInputs.lobbySnapshot
	local outcomes = shopInputs.outcomeByRemoteChannelName
	local itemRows = {}
	for _, dance in shopInputs.danceCatalogDances do
		if dance.isGrantedToNewPlayers then
			continue
		end
		local isOwned = lobbySnapshot ~= nil and table.find(lobbySnapshot.ownedDanceIds, dance.danceId) ~= nil
		local itemRow = buildItemRow({
			shopItemKind = "Dance",
			itemId = dance.danceId,
			nameText = dance.danceDisplayName,
			starCoinPrice = dance.starCoinPrice,
			isOwned = isOwned,
			isEquipped = isOwned and lobbySnapshot.equippedDanceId == dance.danceId,
			equippedText = "Your stage dance",
			equipButtonText = "Use on stage",
			purchaseOutcome = outcomes.RequestPurchaseDanceWithStarCoins,
			equipOutcome = outcomes.RequestEquipDance,
		}, lobbySnapshot)
		table.insert(itemRows, itemRow)
	end
	return {
		groupTitleText = "Dances",
		emptyGroupText = if #itemRows == 0 then ShopPanelModelBuilder.NO_DANCES_FOR_SALE_TEXT else "",
		itemRows = itemRows,
	}
end

local function buildCosmeticGroup(shopInputs, cosmeticKind: string)
	local lobbySnapshot = shopInputs.lobbySnapshot
	local outcomes = shopInputs.outcomeByRemoteChannelName
	local itemRows = {}
	for _, cosmetic in shopInputs.cosmeticCatalog.listCosmeticsOfKind(cosmeticKind) do
		local isOwned = lobbySnapshot ~= nil and table.find(lobbySnapshot.ownedCosmeticIds, cosmetic.cosmeticId) ~= nil
		local itemRow = buildItemRow({
			shopItemKind = "Cosmetic",
			itemId = cosmetic.cosmeticId,
			nameText = cosmetic.cosmeticDisplayName,
			starCoinPrice = cosmetic.starCoinPrice,
			isOwned = isOwned,
			isEquipped = isOwned and lobbySnapshot.equippedCosmeticIdByKind[cosmeticKind] == cosmetic.cosmeticId,
			equippedText = "Equipped",
			equipButtonText = "Equip",
			purchaseOutcome = outcomes.RequestPurchaseCosmeticWithStarCoins,
			equipOutcome = outcomes.RequestEquipCosmetic,
		}, lobbySnapshot)
		itemRow.cosmeticKind = cosmeticKind
		itemRow.preview = buildPreview(cosmetic.cosmeticId, shopInputs.findCosmeticPresentation)
		table.insert(itemRows, itemRow)
	end
	return {
		groupTitleText = GROUP_TITLE_TEXT_BY_COSMETIC_KIND[cosmeticKind] or cosmeticKind,
		emptyGroupText = if #itemRows == 0 then "Nothing for sale here yet." else "",
		itemRows = itemRows,
	}
end

function ShopPanelModelBuilder.buildShopPanelModel(shopInputs)
	local lobbySnapshot = shopInputs.lobbySnapshot
	local groups = { buildDanceGroup(shopInputs) }
	for _, cosmeticKind in shopInputs.cosmeticCatalog.COSMETIC_KINDS do
		table.insert(groups, buildCosmeticGroup(shopInputs, cosmeticKind))
	end
	return {
		loadingText = if lobbySnapshot == nil then ShopPanelModelBuilder.LOADING_TEXT else "",
		balanceText = if lobbySnapshot ~= nil
			then "You have " .. formatStarCoins(lobbySnapshot.shownStarCoinBalance)
			else "",
		groups = groups,
	}
end

return table.freeze(ShopPanelModelBuilder)
