-- Hotspot -> eduroam auto-switch
local HOTSPOT  = "YOUR_HOTSPOT_NAME_REPLACE_ME"
local SCHOOL   = "eduroam"
local RSSI_MIN = -70   -- dBm, ignore weaker eduroam
local NEEDED   = 3     -- consecutive strong scans, 60s apart (~3 min)
local WAKE_DELAY = 20  -- seconds to let macOS join eduroam on wake before falling back
local streak   = 0

local function log(msg) print("[hotspot] " .. msg) end

local function notify(title, text)
  hs.notify.new({ title = title, informativeText = text, withdrawAfter = 10 }):send()
end

local function hotspotPass()
  local out = hs.execute("security find-generic-password -s hs-hotspot -w") or ""
  return (out:gsub("%s+$", ""))   -- parens: return only the string, not gsub's count
end

local function joinHotspot(reason)
  local ok = hs.wifi.associate(HOTSPOT, hotspotPass())
  log(reason .. ", rejoin hotspot: " .. tostring(ok))
  return ok
end

local function online(cb)
  hs.http.asyncGet("http://captive.apple.com/hotspot-detect.html", nil,
    function(code, body) cb(code == 200 and body ~= nil and body:find("Success") ~= nil) end)
end

local function trySwitch()
  log("switching to " .. SCHOOL)
  hs.wifi.disassociate()   -- hotspot Auto-Join is off, so macOS picks eduroam
  switchTimer = hs.timer.doAfter(30, function()
    online(function(ok)
      local net = hs.wifi.currentNetwork()
      if ok and net == SCHOOL then
        log("on eduroam")
        notify("Switched to eduroam", "Left the hotspot. Phone hotspot will turn itself off.")
      else
        local back = joinHotspot("switch failed (on " .. tostring(net) .. ")")
        notify("eduroam switch failed",
          back and "Back on the hotspot." or "Couldn't rejoin the hotspot either. Check Wi-Fi.")
      end
    end)
  end)
end

-- globals so they don't get garbage-collected
scanTimer = hs.timer.doEvery(60, function()
  if hs.wifi.currentNetwork() ~= HOTSPOT then streak = 0 return end
  lastScan = hs.wifi.backgroundScan(function(nets)
    if type(nets) ~= "table" then log("scan error: " .. tostring(nets)) return end
    local best = -999
    for _, n in ipairs(nets) do
      if n.ssid == SCHOOL and n.rssi and n.rssi > best then best = n.rssi end
    end
    streak = (best >= RSSI_MIN) and streak + 1 or 0
    log(string.format("eduroam best=%d dBm, streak=%d/%d", best, streak, NEEDED))
    if streak >= NEEDED then streak = 0; trySwitch() end
  end)
end)

-- woke up with no Wi-Fi (e.g. on the bus)? rejoin the hotspot
wakeWatcher = hs.caffeinate.watcher.new(function(e)
  if e ~= hs.caffeinate.watcher.systemDidWake then return end
  wakeTimer = hs.timer.doAfter(WAKE_DELAY, function()
    if not hs.wifi.currentNetwork() and joinHotspot("woke with no Wi-Fi") then
      notify("Rejoined hotspot", "Mac woke with no Wi-Fi.")
    end
  end)
end):start()

-- Console helpers
hotspotDebug = {
  switch = trySwitch,
  streak = function() return streak end,
  notify = function() notify("Hotspot test", "Notifications work.") end,
}
