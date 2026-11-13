-- Hotspot -> eduroam / home Wi-Fi auto-switch
local HOTSPOT  = "REPLACE_THIS_WITH_YOUR_HOTSPOT"
local SCHOOL   = "eduroam"
local HOME     = "REPLACE_THIS_WITH_YOUR_HOME_WIFI"   -- TODO: your home Wi-Fi name, exactly as the Wi-Fi menu shows it
local TARGETS  = { [SCHOOL] = true, [HOME] = true }   -- leave the hotspot for any of these
local RSSI_MIN = -70   -- dBm, ignore weaker signals
local NEEDED   = 3     -- consecutive strong scans, 60s apart (~3 min)
local WAKE_DELAY = 20  -- seconds to let macOS join eduroam/home on wake before falling back
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

local function trySwitch(target)
  log("switching to " .. target)
  hs.wifi.disassociate()   -- hotspot Auto-Join is off, so macOS picks eduroam/home
  switchTimer = hs.timer.doAfter(30, function()
    online(function(ok)
      local net = hs.wifi.currentNetwork()
      if ok and TARGETS[net] then
        log("on " .. net)
        notify("Switched to " .. net, "Left the hotspot. Phone hotspot will turn itself off.")
      else
        local back = joinHotspot("switch failed (on " .. tostring(net) .. ")")
        notify(target .. " switch failed",
          back and "Back on the hotspot." or "Couldn't rejoin the hotspot either. Check Wi-Fi.")
      end
    end)
  end)
end

-- scan only while on the hotspot: start/stop the timer to match the current network
local function syncScanning()
  local onHotspot = hs.wifi.currentNetwork() == HOTSPOT
  if onHotspot == scanTimer:running() then return end
  streak = 0
  if onHotspot then scanTimer:start() else scanTimer:stop() end
  log(onHotspot and "on hotspot, scanning started" or "off hotspot, scanning stopped")
end

-- globals so they don't get garbage-collected
scanTimer = hs.timer.new(60, function()
  if hs.wifi.currentNetwork() ~= HOTSPOT then return syncScanning() end   -- missed a network change
  lastScan = hs.wifi.backgroundScan(function(nets)
    if type(nets) ~= "table" then log("scan error: " .. tostring(nets)) return end
    if hs.wifi.currentNetwork() ~= HOTSPOT then return end   -- left the hotspot mid-scan
    local best, bestSSID = -999, nil
    for _, n in ipairs(nets) do
      if TARGETS[n.ssid] and n.rssi and n.rssi > best then best, bestSSID = n.rssi, n.ssid end
    end
    streak = (best >= RSSI_MIN) and streak + 1 or 0
    log(string.format("best=%s (%d dBm), streak=%d/%d", bestSSID or "none", best, streak, NEEDED))
    if streak >= NEEDED then streak = 0; trySwitch(bestSSID) end
  end)
end)

wifiWatcher = hs.wifi.watcher.new(syncScanning):start()
syncScanning()   -- set the initial state on config (re)load

-- woke up with no Wi-Fi (e.g. on the bus)? rejoin the hotspot
wakeWatcher = hs.caffeinate.watcher.new(function(e)
  if e ~= hs.caffeinate.watcher.systemDidWake then return end
  wakeTimer = hs.timer.doAfter(WAKE_DELAY, function()
    if not hs.wifi.currentNetwork() and joinHotspot("woke with no Wi-Fi") then
      notify("Rejoined hotspot", "Mac woke with no Wi-Fi.")
    end
    syncScanning()   -- in case a network change was missed during sleep
  end)
end):start()

-- Console helpers
hotspotDebug = {
  switch = function(target) trySwitch(target or SCHOOL) end,
  streak = function() return streak end,
  scanning = function() return scanTimer:running() end,
  notify = function() notify("Hotspot test", "Notifications work.") end,
}
