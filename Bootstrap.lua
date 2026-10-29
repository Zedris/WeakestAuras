-- WeakestAuras -- creates the addon's global and refuses to load on a client
-- whose ClassicAPI is missing or older than CLASSICAPI_REQUIRED.
--
-- This file must stay Lua 5.0 and call only stock 1.12 API. Every other file
-- is written in the 5.1 syntax ClassicAPI rewrites at load time, so on a client
-- without a new enough ClassicAPI they may not even compile, and this file is
-- the only one left to tell the player why.

WeakestAuras = CreateFrame("Frame")

-- Builds the saved-variable table and the one field every reader assumes,
-- returning it. Must be called again after the SavedVariables file has run --
-- it executes *after* every addon file on this client and assigns the global
-- outright, so it replaces whatever was built here rather than merging into it.
-- That includes replacing it with nothing: the client writes a registered
-- variable that was nil at logout back out as a literal `WeakestAurasDB = nil`
-- (any 1.12 WTF folder shows the same line for BigWigs' optional profiles), and
-- a session that took the bail-out below never created one. A saved file from
-- such a session therefore wipes the table on every later login, which is why
-- this runs ahead of that bail-out as well as at ADDON_LOADED.
function WeakestAuras.EnsureDB()
	if type(WeakestAurasDB) ~= "table" then WeakestAurasDB = {} end
	if type(WeakestAurasDB.displays) ~= "table" then WeakestAurasDB.displays = {} end
	return WeakestAurasDB
end

WeakestAuras.EnsureDB()

-- ClassicAPI packs its version as X*10000 + Y*100 + Z; untagged local builds
-- carry a sentinel meaning "newer than every release".
local CLASSICAPI_DEV = 99999999

-- "X.Y.Z" from a packed ClassicAPI version, "dev" for the sentinel. With no
-- argument, the running client's own; nil when it cannot answer.
function WeakestAuras.ClassicAPIVersionString(packed)
	if packed == nil then packed = CLASSIC_API_VERSION end
	if type(packed) ~= "number" then return nil end
	if packed == CLASSICAPI_DEV then return "dev" end
	return math.floor(packed / 10000) .. "."
		.. math.floor(math.mod(packed, 10000) / 100) .. "."
		.. math.mod(packed, 100)
end

-- The only ClassicAPI this addon supports. Everything it provides up to this
-- release is called directly, with no capability or version checks; raise this
-- when the addon starts using something newer.
WeakestAuras.CLASSICAPI_REQUIRED = 11800 -- 1.18.0
WeakestAuras.CLASSICAPI_URL = "https://github.com/brues-code/ClassicAPI/releases/latest"

if type(CLASSIC_API_VERSION) ~= "number" or CLASSIC_API_VERSION < WeakestAuras.CLASSICAPI_REQUIRED then
	WeakestAuras.disabled = true

	local need = WeakestAuras.ClassicAPIVersionString(WeakestAuras.CLASSICAPI_REQUIRED)
	local have = WeakestAuras.ClassicAPIVersionString()
	local detail
	if have then
		detail = "It needs ClassicAPI " .. need .. " or newer, and this client has " .. have .. "."
	else
		detail = "It needs ClassicAPI " .. need .. " or newer, which this client does not have."
	end
	detail = detail .. " Install the latest release from:"

	StaticPopupDialogs["WEAKESTAURAS_CLASSICAPI_REQUIRED"] = {
		text = "|cffff0000WeakestAuras|r has been disabled.\n\n" .. detail,
		button1 = OKAY,
		hasEditBox = 1,
		editBoxWidth = 280,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		OnShow = function()
			local editBox = getglobal(this:GetName() .. "EditBox")
			if editBox then
				editBox:SetText(WeakestAuras.CLASSICAPI_URL)
				editBox:HighlightText()
				editBox:SetFocus()
			end
		end,
	}

	-- Deferred to the first world entry: a line printed while addons load is
	-- buried under every other addon's.
	WeakestAuras:RegisterEvent("PLAYER_ENTERING_WORLD")
	WeakestAuras:SetScript("OnEvent", function()
		WeakestAuras:UnregisterEvent("PLAYER_ENTERING_WORLD")
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r disabled: " .. detail .. " "
			.. WeakestAuras.CLASSICAPI_URL, 1, 0.3, 0.3)
		StaticPopup_Show("WEAKESTAURAS_CLASSICAPI_REQUIRED")
	end)
end
