-- LeaderboardPanelView (spec §1.11, §2.11): the fan leaderboard panel, opened and closed from the
-- status bar (or the L key). It shows FanCountLeaderboardRequester's panel model; WHEN to ask the
-- server is the requester's decision (never more often than every 5 s).
--
-- PUBLIC API
--   LeaderboardPanelView.create(screenGui, onRefreshActivated, onCloseActivated) -> view
--   view:setOpen(isOpen)   view:isOpen() -> boolean
--   view:render(leaderboardPanelModel)
--   Instances (for checks in a playtest): <screenGui>.LeaderboardPanel with StatusLabel,
--   LocalPlayerRankLabel, RefreshButton, CloseButton, RowList.Row1..n (Rank/Name/Fans labels).
--
-- Roblox API used: see DeviceInterfaceElementFactory; Instance:Destroy, :GetChildren, :IsA
--   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local LeaderboardPanelView = {}
LeaderboardPanelView.__index = LeaderboardPanelView

local COLORS = DeviceInterfaceElementFactory.COLORS

function LeaderboardPanelView.create(screenGui: ScreenGui, onRefreshActivated: () -> (), onCloseActivated: () -> ())
	local panel = DeviceInterfaceElementFactory.createPanel("LeaderboardPanel", screenGui)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -10, 0, 130)
	panel.Size = UDim2.new(0.3, 0, 1, -140)
	panel.ZIndex = 5
	panel.Visible = false
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 190)
	header.Parent = panel
	DeviceInterfaceElementFactory.createVerticalList(header, 4)
	DeviceInterfaceElementFactory.createTextLabel("Title", header, 22, 1).Text = "Top fans"
	local statusLabel = DeviceInterfaceElementFactory.createTextLabel("StatusLabel", header, 16, 2)
	local rankLabel = DeviceInterfaceElementFactory.createTextLabel("LocalPlayerRankLabel", header, 18, 3)
	DeviceInterfaceElementFactory.createTextButton("RefreshButton", header, "Refresh", 4, onRefreshActivated)
	DeviceInterfaceElementFactory.createTextButton("CloseButton", header, "Close (L)", 5, onCloseActivated)
	local rowList = DeviceInterfaceElementFactory.createScrollingList("RowList", panel)
	rowList.Position = UDim2.fromOffset(0, 196)
	rowList.Size = UDim2.new(1, 0, 1, -196)
	DeviceInterfaceElementFactory.createVerticalList(rowList, 4)
	return setmetatable({
		panel = panel,
		statusLabel = statusLabel,
		rankLabel = rankLabel,
		rowList = rowList,
		renderedRowsSignature = nil,
	}, LeaderboardPanelView)
end

function LeaderboardPanelView:setOpen(isOpen: boolean)
	self.panel.Visible = isOpen
end

function LeaderboardPanelView:isOpen(): boolean
	return self.panel.Visible
end

function LeaderboardPanelView:render(leaderboardPanelModel)
	self.statusLabel.Text = leaderboardPanelModel.statusText
	self.statusLabel.Visible = leaderboardPanelModel.statusText ~= ""
	self.rankLabel.Text = leaderboardPanelModel.localPlayerRankText
	local signatureParts = {}
	for _, row in leaderboardPanelModel.rows do
		table.insert(signatureParts, row.rankText .. row.playerNameText .. row.fanCountText)
	end
	local signature = table.concat(signatureParts, "\n")
	if signature == self.renderedRowsSignature then
		return
	end
	self.renderedRowsSignature = signature
	for _, child in self.rowList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for rowPosition, row in leaderboardPanelModel.rows do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "Row" .. rowPosition
		rowFrame.Size = UDim2.new(1, -12, 0, 36)
		rowFrame.BorderSizePixel = 0
		rowFrame.BackgroundColor3 = if row.isLocalPlayer then COLORS.localPlayerRowBackground else COLORS.itemBackground
		rowFrame.LayoutOrder = rowPosition
		rowFrame.Parent = self.rowList
		local columns = {
			{ "Rank", row.rankText, 0, 0.18 },
			{ "Name", row.playerNameText, 0.18, 0.5 },
			{ "Fans", row.fanCountText, 0.68, 0.32 },
		}
		for _, column in columns do
			local label = DeviceInterfaceElementFactory.createTextLabel(column[1], rowFrame, 16, 0)
			label.AutomaticSize = Enum.AutomaticSize.None
			label.Position = UDim2.fromScale(column[3], 0)
			label.Size = UDim2.fromScale(column[4], 1)
			label.Text = column[2]
		end
	end
end

return LeaderboardPanelView
