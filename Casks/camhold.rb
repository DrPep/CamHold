cask "camhold" do
  version "1.0"
  sha256 "f4638ab21a8b3b6f6262504560e02f841ed7fe790e28042b255b33dcabc2eeb4"

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
