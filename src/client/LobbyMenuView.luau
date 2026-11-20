-- LobbyMenuView (development spec §0.2 "Lobby and dance floor", decision 16 "touch first"): the lobby
-- menu's frame: one large "Menu" button and, when open, a panel with five large tab buttons (Dances,
-- Shop, Daily, Codes, Outfit) and one content frame per panel, of which only the chosen one is shown.
-- It shows LobbyMenuNavigation's model; whether the menu is available, open, and on which panel is
-- decided there. The panel views draw into the content frames.
-- Placement: the left column below the status bar, the place the round wardrobe uses; the menu is
-- never available while the round wardrobe is shown (a Styling participant), so they never overlap,
-- and the centre round panel stays clear.
--
-- PUBLIC API
--   LobbyMenuView.create(screenGui, { onMenuButtonActivated(), onTabActivated(panelName) }) -> view
--   view.contentFrameByPanelName   { [panelName]: Frame }
--   view:render(lobbyMenuModel)
--   Instances (for checks in a playtest): <screenGui>.LobbyMenuButton (attribute IsEnabled) and
--   <screenGui>.LobbyMenuPanel with Tabs.Tab_<panelName> (attribute IsSelected) and
--   Content_<panelName>; the panel carries the attributes IsOpen and OpenPanelName.
--
-- Roblox API used: see DeviceInterfaceElementFactory; UIGridLayout .CellSize, .CellPadding, .SortOrder
--   (the grid sets each child's size and position)   https://create.roblox.com/docs/reference/engine/classes/UIGridLayout
--   Instance:SetAttribute   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")
local LobbyMenuNavigation = require("./LobbyMenuNavigation")

local LobbyMenuView = {}
LobbyMenuView.__index = LobbyMenuView

local COLORS = DeviceInterfaceElementFactory.COLORS
local TOP_PIXELS = 130
local TABS_HEIGHT_PIXELS = 116

function LobbyMenuView.create(screenGui: ScreenGui, callbacks)
	local menuButton = DeviceInterfaceElementFactory.createTextButton(
		"LobbyMenuButton",
		screenGui,
		"Menu (M)",
		0,
		callbacks.onMenuButtonActivated
	)
	menuButton.Position = UDim2.fromOffset(10, TOP_PIXELS)
	menuButton.Size = UDim2.new(0.3, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	local panel = DeviceInterfaceElementFactory.createPanel("LobbyMenuPanel", screenGui)
	panel.Position = UDim2.fromOffset(10, TOP_PIXELS + 60)
	panel.Size = UDim2.new(0.3, 0, 1, -(TOP_PIXELS + 70))
	panel.Visible = false
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Size = UDim2.new(1, 0, 0, TABS_HEIGHT_PIXELS)
	tabs.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / 3, -4, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	grid.CellPadding = UDim2.fromOffset(4, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = tabs
	local view = setmetatable({
		menuButton = menuButton,
		panel = panel,
		tabButtonByPanelName = {},
		contentFrameByPanelName = {},
	}, LobbyMenuView)
	for tabPosition, panelName in LobbyMenuNavigation.LOBBY_PANEL_NAMES do
		local tabButton = DeviceInterfaceElementFactory.createTextButton(
			"Tab_" .. panelName,
			tabs,
			panelName,
			tabPosition,
			function()
				callbacks.onTabActivated(panelName)
			end
		)
		tabButton.TextSize = 18
		view.tabButtonByPanelName[panelName] = tabButton
		local contentFrame = Instance.new("Frame")
		contentFrame.Name = "Content_" .. panelName
		contentFrame.BackgroundTransparency = 1
		contentFrame.Position = UDim2.fromOffset(0, TABS_HEIGHT_PIXELS + 8)
		contentFrame.Size = UDim2.new(1, 0, 1, -(TABS_HEIGHT_PIXELS + 8))
		contentFrame.Visible = false
		contentFrame.Parent = panel
		view.contentFrameByPanelName[panelName] = contentFrame
	end
	return view
end

function LobbyMenuView:render(lobbyMenuModel)
	self.menuButton.Visible = lobbyMenuModel.isMenuButtonVisible
	self.menuButton.Text = lobbyMenuModel.menuButtonText
	self.panel.Visible = lobbyMenuModel.isMenuOpen
	self.panel:SetAttribute("IsOpen", lobbyMenuModel.isMenuOpen)
	self.panel:SetAttribute("OpenPanelName", lobbyMenuModel.openPanelName)
	for _, tab in lobbyMenuModel.tabs do
		local tabButton = self.tabButtonByPanelName[tab.panelName]
		tabButton.Text = tab.tabText
		tabButton.BackgroundColor3 = if tab.isSelected then COLORS.selectedItemBackground else COLORS.buttonBackground
		tabButton:SetAttribute("IsSelected", tab.isSelected)
		self.contentFrameByPanelName[tab.panelName].Visible = tab.isSelected and lobbyMenuModel.isMenuOpen
	end
end

return LobbyMenuView
