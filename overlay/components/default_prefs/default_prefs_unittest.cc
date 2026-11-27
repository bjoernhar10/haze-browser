// Copyright 2026 The Haze Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "haze/components/default_prefs/default_prefs.h"

#include "base/values.h"
#include "chrome/common/pref_names.h"
#include "components/pref_registry/pref_registry_syncable.h"
#include "components/privacy_sandbox/privacy_sandbox_prefs.h"
#include "components/sync_preferences/testing_pref_service_syncable.h"
#include "components/universal_optout/prefs.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/blink/public/common/peerconnection/webrtc_ip_handling_policy.h"

namespace haze {
namespace {

// Registers the prefs the hook changes, with the defaults Chromium registers
// them with, then applies the hook the way RegisterProfilePrefs does.
class HazeDefaultPrefsTest : public testing::Test {
 protected:
  void SetUp() override {
    user_prefs::PrefRegistrySyncable* registry = prefs_.registry();
    // Registered by chrome/browser/ui/browser_ui_prefs.cc, which this
    // component may not depend on; mirrored here with the same defaults.
    registry->RegisterBooleanPref(
        prefs::kHttpsOnlyModeEnabled, false,
        user_prefs::PrefRegistrySyncable::SYNCABLE_PREF);
    registry->RegisterStringPref(prefs::kWebRTCIPHandlingPolicy,
                                 blink::kWebRTCIPHandlingDisableNonProxiedUdp);
    universal_optout::prefs::RegisterProfilePrefs(registry);
    privacy_sandbox::RegisterProfilePrefs(registry);

    SetProfilePrefDefaults(registry);
  }

  sync_preferences::TestingPrefServiceSyncable prefs_;
};

TEST_F(HazeDefaultPrefsTest, HttpsFirstWarnsBeforeEveryHttpPage) {
  EXPECT_TRUE(prefs_.GetBoolean(prefs::kHttpsOnlyModeEnabled));
  EXPECT_TRUE(prefs_.FindPreference(prefs::kHttpsOnlyModeEnabled)
                  ->IsDefaultValue());
}

TEST_F(HazeDefaultPrefsTest, WebRtcUsesDefaultPublicInterfaceOnly) {
  EXPECT_EQ(prefs_.GetString(prefs::kWebRTCIPHandlingPolicy),
            blink::kWebRTCIPHandlingDefaultPublicInterfaceOnly);
}

TEST_F(HazeDefaultPrefsTest, GlobalPrivacyControlIsOn) {
  EXPECT_TRUE(
      prefs_.GetBoolean(universal_optout::prefs::kUniversalOptOutEnabled));
}

TEST_F(HazeDefaultPrefsTest, RelatedWebsiteSetsAreOff) {
  EXPECT_FALSE(
      prefs_.GetBoolean(prefs::kPrivacySandboxRelatedWebsiteSetsEnabled));
}

// A value the user chose is a user value, which a changed default never
// overrides, also not when the defaults are applied again on the next start.
TEST_F(HazeDefaultPrefsTest, UserChoicesSurviveTheDefaults) {
  prefs_.SetBoolean(prefs::kHttpsOnlyModeEnabled, false);
  prefs_.SetString(prefs::kWebRTCIPHandlingPolicy,
                   blink::kWebRTCIPHandlingDefault);
  prefs_.SetBoolean(universal_optout::prefs::kUniversalOptOutEnabled, false);
  prefs_.SetBoolean(prefs::kPrivacySandboxRelatedWebsiteSetsEnabled, true);

  SetProfilePrefDefaults(prefs_.registry());

  EXPECT_FALSE(prefs_.GetBoolean(prefs::kHttpsOnlyModeEnabled));
  EXPECT_EQ(prefs_.GetString(prefs::kWebRTCIPHandlingPolicy),
            blink::kWebRTCIPHandlingDefault);
  EXPECT_FALSE(
      prefs_.GetBoolean(universal_optout::prefs::kUniversalOptOutEnabled));
  EXPECT_TRUE(
      prefs_.GetBoolean(prefs::kPrivacySandboxRelatedWebsiteSetsEnabled));
}

}  // namespace
}  // namespace haze
