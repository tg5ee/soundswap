-- Native callback routing, without changing the running compositor.
local callbacks, played, binds = {}, {}, {}
hl = {
  on = function(event, fn) callbacks[event] = fn end,
  exec_cmd = function(command) table.insert(played, command:match(" ([%w-]+)$")) end,
  get_active_workspace = function() return {id = 1} end,
  dsp = {exec_cmd = function(command) return command end},
  bind = function(key, _, flags)
    assert(flags.non_consuming and flags.ignore_mods)
    table.insert(binds, key)
  end,
}
o = {bind = function(_, _, _, flags) assert(flags.release and flags.non_consuming) end}
dofile('hypr/beepboop.lua')
callbacks['workspace.active']({id=1})
assert(#played == 0)
callbacks['workspace.active']({id=2})
callbacks['workspace.active']({id=2})
assert(#played == 1 and played[1] == 'workspace')
assert(callbacks['workspace.special_active'], 'Special workspace callback missing')
callbacks['workspace.special_active']({id=-99})
assert(played[#played] == 'workspace')
callbacks['window.fullscreen']({fullscreen=2})
assert(played[#played] == 'maximize')
callbacks['window.fullscreen']({fullscreen=0})
assert(played[#played] == 'restore')
callbacks['layer.opened']({namespace='omarchy-menu'})
assert(played[#played] == 'menu-open')
callbacks['layer.closed']({namespace='omarchy-menu'})
assert(played[#played] == 'menu-close')
callbacks['layer.opened']({namespace='omarchy-polkit'})
assert(played[#played] == 'auth-prompt')
assert(#binds == 6)
print('Hyprland routing checks passed')
