-- StatusBarView: the always-visible strip at the top of the screen (spec §2.6): Star Coins and fans
-- from the latest save snapshot, the save notices, and the button that opens the leaderboard. It only
-- shows PlayerSaveDataStatusBarModel's model; it decides nothing.
--
-- PUBLIC API
--   StatusBarView.create(screenGui, onLeaderboardButtonActivated) -> view
--   view:render(statusBarModel)
--   Instances (for checks in a playtest): <screenGui>.StatusBar.StarCoinBalanceLabel,
--   .FanCountLabel, .LeaderboardButton, .Notices.Notice1..n
--
-- Roblox API used: see DeviceInterfaceElementFactory (Frame, TextLabel, UIListLayout, UDim2);
--   Instance:Destroy, :GetChildren, :IsA   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local StatusBarView = {}
StatusBarView.__index = StatusBarView

function StatusBarView.create(screenGui: ScreenGui, onLeaderboardButtonActivated: () -> ())
	local bar = DeviceInterfaceElementFactory.createPanel("StatusBar", screenGui)
	bar.Size = UDim2.new(1, -20, 0, 64)
	bar.Position = UDim2.fromOffset(10, 6)
	local starCoinLabel = DeviceInterfaceElementFactory.createTextLabel("StarCoinBalanceLabel", bar, 20, 1)
	starCoinLabel.AutomaticSize = Enum.AutomaticSize.None
	starCoinLabel.Size = UDim2.fromScale(0.3, 1)
	starCoinLabel.TextXAlignment = Enum.TextXAlignment.Left
	local fanLabel = DeviceInterfaceElementFactory.createTextLabel("FanCountLabel", bar, 20, 2)
	fanLabel.AutomaticSize = Enum.AutomaticSize.None
	fanLabel.Size = UDim2.fromScale(0.3, 1)
	fanLabel.Position = UDim2.fromScale(0.3, 0)
	fanLabel.TextXAlignment = Enum.TextXAlignment.Left
	local leaderboardButton = DeviceInterfaceElementFactory.createTextButton(
		"LeaderboardButton",
		bar,
		"Leaderboard (L)",
		3,
		onLeaderboardButtonActivated
	)
	leaderboardButton.Size = UDim2.new(0.3, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	leaderboardButton.AnchorPoint = Vector2.new(1, 0.5)
	leaderboardButton.Position = UDim2.fromScale(1, 0.5)
	local notices = Instance.new("Frame")
	notices.Name = "Notices"
	notices.BackgroundTransparency = 1
	notices.Size = UDim2.new(1, -20, 0, 0)
	notices.AutomaticSize = Enum.AutomaticSize.Y
	notices.Position = UDim2.fromOffset(10, 74)
	notices.Parent = screenGui
	DeviceInterfaceElementFactory.createVerticalList(notices, 4)
	return setmetatable({
		starCoinLabel = starCoinLabel,
		fanLabel = fanLabel,
		notices = notices,
	}, StatusBarView)
end

function StatusBarView:render(statusBarModel)
	self.starCoinLabel.Text = "Star Coins: " .. statusBarModel.starCoinBalanceText
	self.fanLabel.Text = "Fans: " .. statusBarModel.fanCountText
	local noticeSignature = table.concat(statusBarModel.noticeTexts, "\n")
	if noticeSignature == self.renderedNoticeSignature then
		return
	end
	self.renderedNoticeSignature = noticeSignature
	for _, child in self.notices:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for noticePosition, noticeText in statusBarModel.noticeTexts do
		local noticeLabel =
			DeviceInterfaceElementFactory.createTextLabel("Notice" .. noticePosition, self.notices, 18, noticePosition)
		noticeLabel.TextColor3 = DeviceInterfaceElementFactory.COLORS.noticeText
		noticeLabel.Text = noticeText
	end
end

return StatusBarView
