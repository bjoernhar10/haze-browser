// Copyright 2026 The Haze Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "haze/components/default_prefs/default_prefs.h"

#include "base/values.h"
#include "chrome/common/pref_names.h"
#include "components/pref_registry/pref_registry_syncable.h"
#include "components/privacy_sandbox/privacy_sandbox_prefs.h"
#include "components/universal_optout/prefs.h"
#include "third_party/blink/public/common/peerconnection/webrtc_ip_handling_policy.h"

namespace haze {

void SetProfilePrefDefaults(user_prefs::PrefRegistrySyncable* registry) {
  // HTTPS-First in its strict form: a warning before every page that would
  // load over plain HTTP, not only on sites that probably support HTTPS.
  registry->SetDefaultPrefValue(prefs::kHttpsOnlyModeEnabled,
                                base::Value(true));

  // Keeps local IP addresses away from WebRTC without taking UDP away from
  // calls, which ungoogled's disable_non_proxied_udp does.
  registry->SetDefaultPrefValue(
      prefs::kWebRTCIPHandlingPolicy,
      base::Value(blink::kWebRTCIPHandlingDefaultPublicInterfaceOnly));

  // Global Privacy Control: Sec-GPC: 1 and navigator.globalPrivacyControl.
  registry->SetDefaultPrefValue(
      universal_optout::prefs::kUniversalOptOutEnabled, base::Value(true));

  // Related Website Sets let a declared group of sites read each other's
  // cookies even while third-party cookies are blocked.
  registry->SetDefaultPrefValue(
      prefs::kPrivacySandboxRelatedWebsiteSetsEnabled, base::Value(false));
}

}  // namespace haze
