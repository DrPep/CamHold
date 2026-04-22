cask "camhold" do
  version "1.0"
  sha256 "c1b63371a74d1703b00d744f5dc051dbc72a8fc41632c6cfc48874a381e5a8d4"

  url "https://github.com/YOUR_GH_USER/CamHold/releases/download/v#{version}/CamHold-#{version}.dmg"
  name "CamHold"
  desc "Menu-bar utility that keeps a selected camera warm and ready"
  homepage "https://github.com/YOUR_GH_USER/CamHold"

  depends_on macos: ">= :ventura"

  app "CamHold.app"

  zap trash: [
    "~/Library/Preferences/com.example.CamHold.plist",
    "~/Library/Saved Application State/com.example.CamHold.savedState",
  ]
end
