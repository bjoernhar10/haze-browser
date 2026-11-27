// Copyright 2026 The Haze Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The defaults Haze changes in Chromium's own code (patches/privacy/), checked
// where Chromium defines them. The pref defaults Haze sets through its hook are
// tested in haze/components/default_prefs/.

#include <set>
#include <string>
#include <vector>

#include "base/check.h"
#include "base/feature_list.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/net/default_dns_over_https_config_source.h"
#include "chrome/browser/net/secure_dns_config.h"
#include "chrome/browser/net/secure_dns_util.h"
#include "chrome/browser/ui/webui/new_tab_page/composebox/variations/composebox_fieldtrial.h"
#include "chrome/common/chrome_features.h"
#include "components/attribution_reporting/features.h"
#include "components/compose/core/browser/compose_features.h"
#include "components/country_codes/country_codes.h"
#include "components/optimization_guide/core/optimization_guide_features.h"
#include "components/prefs/testing_pref_service.h"
#include "components/search_engines/template_url_data.h"
#include "components/search_engines/template_url_prepopulate_data.h"
#include "components/sync_preferences/testing_pref_service_syncable.h"
#include "components/universal_optout/features.h"
#include "net/dns/public/doh_provider_entry.h"
#include "services/network/public/cpp/features.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/blink/public/common/features.h"
#include "third_party/blink/public/common/features_generated.h"

namespace haze {
namespace {

TEST(HazePrivacyDefaultsTest, AiFeaturesAreOff) {
  EXPECT_FALSE(base::FeatureList::IsEnabled(features::kGlic));
  EXPECT_FALSE(base::FeatureList::IsEnabled(features::kGlicActor));
  EXPECT_FALSE(
      base::FeatureList::IsEnabled(compose::features::kEnableCompose));
  EXPECT_FALSE(base::FeatureList::IsEnabled(ntp_composebox::kNtpComposebox));
  EXPECT_FALSE(base::FeatureList::IsEnabled(
      optimization_guide::features::kOptimizationGuideModelExecution));
}

TEST(HazePrivacyDefaultsTest, PrivacySandboxAdApisAreOff) {
  EXPECT_FALSE(base::FeatureList::IsEnabled(network::features::kBrowsingTopics));
  EXPECT_FALSE(base::FeatureList::IsEnabled(
      attribution_reporting::features::kConversionMeasurement));
  EXPECT_FALSE(base::FeatureList::IsEnabled(blink::features::kFencedFrames));
}

TEST(HazePrivacyDefaultsTest, GlobalPrivacyControlIsOn) {
  EXPECT_TRUE(base::FeatureList::IsEnabled(
      universal_optout::features::kUniversalOptOut));
  EXPECT_TRUE(base::FeatureList::IsEnabled(
      universal_optout::features::kUniversalOptOutSettings));
  EXPECT_TRUE(
      base::FeatureList::IsEnabled(blink::features::kGlobalPrivacyControlApi));
}

TEST(HazePrivacyDefaultsTest, SecureDnsUpgradesAutomatically) {
  EXPECT_TRUE(
      base::FeatureList::IsEnabled(network::features::kDnsOverHttpsUpgrade));

  TestingPrefServiceSimple local_state;
  DefaultDnsOverHttpsConfigSource::RegisterPrefs(local_state.registry());
  DefaultDnsOverHttpsConfigSource source(&local_state,
                                         /*set_up_pref_defaults=*/true);
  EXPECT_EQ(source.GetDnsOverHttpsMode(), SecureDnsConfig::kModeAutomatic);
}

TEST(HazePrivacyDefaultsTest, SecureDnsPickerOffersQuad9MullvadCloudflare) {
  // Countries that used to add their own providers to the dropdown, and one
  // that never did.
  for (const char* country : {"DE", "US", "JP", "CZ", "BR"}) {
    std::set<std::string> shown;
    for (const net::DohProviderEntry* entry :
         chrome_browser_net::secure_dns::SelectEnabledProviders(
             chrome_browser_net::secure_dns::ProvidersForCountry(
                 net::DohProviderEntry::GetList(),
                 country_codes::CountryId(country)))) {
      shown.insert(std::string(entry->provider));
    }
    EXPECT_EQ(shown,
              (std::set<std::string>{"Cloudflare", "Mullvad", "Quad9Secure"}))
        << country;
  }
}

TEST(HazePrivacyDefaultsTest, DuckDuckGoIsTheDefaultSearchEngine) {
  sync_preferences::TestingPrefServiceSyncable prefs;
  TemplateURLPrepopulateData::RegisterProfilePrefs(prefs.registry());

  using TemplateURLPrepopulateData::PrepopulatedEngine;
  const auto built_in = [](std::u16string_view keyword) {
    const PrepopulatedEngine* engine =
        TemplateURLPrepopulateData::GetPrepopulatedEngineFromBuiltInData(
            keyword, /*regional_prepopulated_engines=*/{},
            /*regional_variants=*/{});
    CHECK(engine);
    return engine;
  };
  // ungoogled's "No Search" sits where Google was, and comes first.
  const std::vector<raw_ptr<const PrepopulatedEngine>> lists_duckduckgo = {
      built_in(u"nosearch"), built_in(u"bing.com"),
      built_in(u"duckduckgo.com")};
  const std::vector<raw_ptr<const PrepopulatedEngine>> lacks_duckduckgo = {
      built_in(u"nosearch"), built_in(u"bing.com")};

  for (const auto* region : {&lists_duckduckgo, &lacks_duckduckgo}) {
    std::unique_ptr<TemplateURLData> engine =
        TemplateURLPrepopulateData::GetPrepopulatedFallbackSearch(prefs,
                                                                  *region);
    ASSERT_TRUE(engine);
    EXPECT_EQ(engine->keyword(), u"duckduckgo.com");
  }
}

}  // namespace
}  // namespace haze
