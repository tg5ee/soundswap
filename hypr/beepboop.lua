-- BeepBoop — installed by beepboop/install.sh; uninstall.sh removes it.
-- Each hook just calls beepboop-play, which checks your settings in
-- ~/.config/beepboop/config, so toggling sounds never needs a reload.
-- Events Hyprland can't see (lock, notifications, devices, charger) are
-- handled by beepboop-daemon instead.

local function play(event)
  local player = os.getenv("HOME") .. "/.local/bin/beepboop-play"
  return "'" .. player:gsub("'", "'\\''") .. "' " .. event
end

local function on(hypr_event, sound)
  hl.on(hypr_event, function()
    hl.exec_cmd(play(sound))
  end)
end

-- Startup (login)
on("hyprland.start", "startup")

-- Windows
on("window.open", "window-open")
on("window.close", "window-close")
on("window.urgent", "attention")

-- The window arrives with its new state: 0 = normal, anything else = maximized/fullscreen.
hl.on("window.fullscreen", function(window)
  hl.exec_cmd(play(window and window.fullscreen ~= 0 and "maximize" or "restore"))
end)

-- Ordinary workspaces deduplicate identical events; monitor focus has its own event.
local function workspace_key(workspace)
  return workspace and tostring(workspace.id or workspace.name) or nil
end

-- Seeded now so the first switch after a config reload isn't skipped.
local ok, current = pcall(hl.get_active_workspace)
local last_workspace = ok and workspace_key(current) or nil

hl.on("workspace.active", function(workspace)
  local id = workspace_key(workspace)
  if last_workspace ~= nil and id ~= last_workspace then
    hl.exec_cmd(play("workspace"))
  end
  last_workspace = id
end)

-- Scratchpads use a separate native event, on both opening and closing.
on("workspace.special_active", "workspace")

-- Omarchy menu / launcher, and the password (polkit) prompt, are shell layers.
hl.on("layer.opened", function(layer)
  if layer.namespace == "omarchy-menu" then
    hl.exec_cmd(play("menu-open"))
  elseif layer.namespace == "omarchy-polkit" then
    hl.exec_cmd(play("auth-prompt"))
  end
end)

hl.on("layer.closed", function(layer)
  if layer.namespace == "omarchy-menu" then
    hl.exec_cmd(play("menu-close"))
  end
end)

-- Non-consuming binds: the key or click still does its normal job; we just
-- listen. ignore_mods keeps them working with SUPER/ALT held (SUPER + drag, ALT + volume).
local function listen(key, sound)
  hl.bind(key, hl.dsp.exec_cmd(play(sound)), { non_consuming = true, ignore_mods = true })
end

-- Mouse clicks
for _, button in ipairs({ "mouse:272", "mouse:273", "mouse:274" }) do
  listen(button, "click")
end

-- Volume keys (once per press, not on key repeat)
for _, key in ipairs({ "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute" }) do
  listen(key, "volume-keys")
end

-- Tapping Super on its own (fires on release, not when Super is part of a shortcut).
o.bind("SUPER + Super_L", nil, play("super"), { release = true, non_consuming = true })
o.bind("SUPER + Super_R", nil, play("super"), { release = true, non_consuming = true })
