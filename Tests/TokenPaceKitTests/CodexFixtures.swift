import Foundation

// MARK: - CodexFixtures

/// Captured bodies from `status.openai.com`, trimmed to the keys the decoders read.
///
/// Embedded as strings rather than added as bundle resources: `Bundle.module` does not work inside a
/// real `.app`, so this package ships no resource bundle at all and adding one back is a decision of
/// its own (ADR-0095).
///
/// A public status page, so nothing here is private — what is trimmed is volume, not content. The
/// incident set is five hand-picked cases rather than the captured 93: one touching a single Codex
/// component, one touching two, one touching a component Codex does not use (`Sora`, which must not
/// reach the plate), one touching `Login` (excluded because the feed lists it twice under two ids),
/// and one carrying `full_outage` — the word this page uses where Statuspage says `major_outage`.
enum CodexFixtures {

    /// `GET /api/v2/components.json`, every component, minimal keys.
    ///
    /// `updated_at` is the same value on all of them — the measurement the age design rests on, and
    /// the reason a test can assert the key is never read.
    static let components =
        "{\"components\":[{\"id\":\"01JP8CD9JR3HR6Y7G4Q75N4DVW\",\"name\":\"Responses\",\"status\":\"operational\",\"positio" +
        "n\":0,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFE4MAP2BHSJNZ787WX\",\"name\":\"Images\",\"status" +
        "\":\"operational\",\"position\":1,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KMKFAMWKQ81YWSE1Z18R6VHR\"" +
        ",\"name\":\"Codex in ChatGPT Desktop\",\"status\":\"operational\",\"position\":2,\"updated_at\":\"2026-07-09T19:2" +
        "5:56Z\"},{\"id\":\"01JSM5RTJWHRWDTS6Q604VEW3B\",\"name\":\"Login\",\"status\":\"operational\",\"position\":3,\"updat" +
        "ed_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFEKVBWKK82B44QFMCE\",\"name\":\"Audio\",\"status\":\"operation" +
        "al\",\"position\":4,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JNKS9D9S72PMP1938PVFFQN4\",\"name\":\"Com" +
        "pliance API\",\"status\":\"operational\",\"position\":5,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBR" +
        "MFESJCBGJR10PDD3WCQ\",\"name\":\"Files\",\"status\":\"operational\",\"position\":6,\"updated_at\":\"2026-07-09T19:" +
        "25:56Z\"},{\"id\":\"01KKAD7C71MCCH3FTREMJH4AAS\",\"name\":\"FedRAMP\",\"status\":\"operational\",\"position\":7,\"up" +
        "dated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBNJXGKKP51D4DEJ2HZJ8Q\",\"name\":\"Search\",\"status\":\"opera" +
        "tional\",\"position\":8,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01K9G527YRPY1EFRMHTKB5BKT5\",\"name\":" +
        "\"Sora\",\"status\":\"operational\",\"position\":9,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KVR95C58GGW" +
        "HV7RYBT32NP11\",\"name\":\"Ads API\",\"status\":\"operational\",\"position\":10,\"updated_at\":\"2026-07-09T19:25:" +
        "56Z\"},{\"id\":\"01JMXBRMFEMZK0HPK19RYET250\",\"name\":\"Fine-tuning\",\"status\":\"operational\",\"position\":11,\"" +
        "updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01K8C008QVXHA6JX98PAS42VPD\",\"name\":\"ChatGPT Atlas\",\"statu" +
        "s\":\"operational\",\"position\":12,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JSYVYQSWMJ9QG35XHP08BHA" +
        "7\",\"name\":\"Deep Research\",\"status\":\"operational\",\"position\":13,\"updated_at\":\"2026-07-09T19:25:56Z\"}," +
        "{\"id\":\"01JSG1XMJ9RVJJQ0E85NVSJ2AZ\",\"name\":\"Agent\",\"status\":\"operational\",\"position\":14,\"updated_at\":" +
        "\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFEQW613TFE89F45035\",\"name\":\"Realtime\",\"status\":\"operational\"," +
        "\"position\":15,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBNJXGGT5SR5DB9J7GYY48\",\"name\":\"Voice " +
        "mode\",\"status\":\"operational\",\"position\":16,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFE5ES" +
        "NNV8JDHVCGSRD\",\"name\":\"Batch\",\"status\":\"operational\",\"position\":17,\"updated_at\":\"2026-07-09T19:25:56" +
        "Z\"},{\"id\":\"01JMXBRMFEV0AJ0VVS68N9CD6R\",\"name\":\"Embeddings\",\"status\":\"operational\",\"position\":18,\"upd" +
        "ated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFEVZ7E0X9GD9FWR9WX\",\"name\":\"Moderations\",\"status\":\"o" +
        "perational\",\"position\":19,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JVCV8YSWZFRSM1G5CVP253SK\",\"n" +
        "ame\":\"Codex Web\",\"status\":\"operational\",\"position\":20,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01" +
        "K6TVGGGDCP0PPGCHXAG3AQX8\",\"name\":\"Connectors/Apps\",\"status\":\"operational\",\"position\":21,\"updated_at\"" +
        ":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KMP3KP5M8X0EBTVW6KN327EE\",\"name\":\"VS Code extension\",\"status\":\"ope" +
        "rational\",\"position\":22,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KMP3KP5MGE23B80K1EK4S8PV\",\"nam" +
        "e\":\"Codex API\",\"status\":\"operational\",\"position\":23,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KX" +
        "45G1SHQQ9DTAX9S4W7FV8G\",\"name\":\"Sites\",\"status\":\"operational\",\"position\":24,\"updated_at\":\"2026-07-09" +
        "T19:25:56Z\"},{\"id\":\"01JMXBNJXG1YMQPPCPCQX3MPA2\",\"name\":\"File uploads\",\"status\":\"operational\",\"positi" +
        "on\":25,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBRMFE6N2NNT7DG6XZQ6PW\",\"name\":\"Chat Completi" +
        "ons\",\"status\":\"operational\",\"position\":26,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBNJXG1S2D" +
        "9V65P1ZZTD94\",\"name\":\"Login\",\"status\":\"operational\",\"position\":27,\"updated_at\":\"2026-07-09T19:25:56Z" +
        "\"},{\"id\":\"01KTQBYVARFJ5KMCSECM06VKCF\",\"name\":\"Ads Manager\",\"status\":\"operational\",\"position\":28,\"upd" +
        "ated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KMKFAMWKNQ84Z1766MV08ZDE\",\"name\":\"CLI\",\"status\":\"operation" +
        "al\",\"position\":29,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JMXBNJXGV1T5GT2M9XA83XNG\",\"name\":\"Co" +
        "nversations\",\"status\":\"operational\",\"position\":30,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01JSFK" +
        "5QX36ZRW0TW0ZV0ZYFXQ\",\"name\":\"GPTs\",\"status\":\"operational\",\"position\":31,\"updated_at\":\"2026-07-09T19" +
        ":25:56Z\"},{\"id\":\"01JQ7EKW990MSPSWVXC7VPV2ZJ\",\"name\":\"Image Generation\",\"status\":\"operational\",\"posit" +
        "ion\":32,\"updated_at\":\"2026-07-09T19:25:56Z\"},{\"id\":\"01KX45G1SH21AX5DT93D4HMF0P\",\"name\":\"ChatGPT Work" +
        "\",\"status\":\"operational\",\"position\":33,\"updated_at\":\"2026-07-09T19:25:56Z\"}]}"

    /// Five incidents from `GET /proxy/status.openai.com/incidents`, in that feed's own shape.
    static let proxyIncidents =
        "{\"incidents\":[{\"id\":\"01M0G1RZER839AZXWMYKSZF3GR\",\"name\":\"Elevated Codex API authentication errors\",\"" +
        "status\":\"resolved\",\"published_at\":\"2026-08-20T16:58:53.272Z\",\"affected_components\":[{\"component_id\":" +
        "\"01KMP3KP5MGE23B80K1EK4S8PV\",\"status\":\"degraded_performance\",\"current_status\":\"operational\"}],\"compo" +
        "nent_impacts\":[{\"id\":\"01M0G1RZERVWW6B29BS7SSJ9VH\",\"component_id\":\"01KMP3KP5MGE23B80K1EK4S8PV\",\"statu" +
        "s\":\"degraded_performance\",\"start_at\":\"2026-08-20T16:58:53.272Z\",\"end_at\":\"2026-08-20T17:15:51.764Z\"}" +
        "],\"updates\":[{\"id\":\"01M0G1RZERM19PBWFV956PENSZ\",\"to_status\":\"identified\",\"message_string\":\"Some user" +
        "s may encounter errors when using Codex with API authentication.\\n\\nWe are working on implementing a" +
        " mitigation.\",\"published_at\":\"2026-08-20T16:58:53.272Z\"}]},{\"id\":\"01KXT44TAQQ2R0AZDDVSJGAC4H\",\"name\"" +
        ":\"Some users are unable to access Codex\",\"status\":\"resolved\",\"published_at\":\"2026-07-18T08:05:37.238" +
        "Z\",\"affected_components\":[{\"component_id\":\"01KMKFAMWKNQ84Z1766MV08ZDE\",\"status\":\"degraded_performanc" +
        "e\",\"current_status\":\"operational\"},{\"component_id\":\"01KMKFAMWKQ81YWSE1Z18R6VHR\",\"status\":\"degraded_p" +
        "erformance\",\"current_status\":\"operational\"}],\"component_impacts\":[{\"id\":\"01KXT44TAQSW841YN38DQADC6T\"" +
        ",\"component_id\":\"01KMKFAMWKNQ84Z1766MV08ZDE\",\"status\":\"degraded_performance\",\"start_at\":\"2026-07-18T" +
        "08:05:37.238Z\",\"end_at\":\"2026-07-18T12:58:14.016Z\"},{\"id\":\"01KXT44TAQBPPHKPFST437580S\",\"component_id" +
        "\":\"01KMKFAMWKQ81YWSE1Z18R6VHR\",\"status\":\"degraded_performance\",\"start_at\":\"2026-07-18T08:05:37.238Z\"" +
        ",\"end_at\":\"2026-07-18T12:58:14.016Z\"}],\"updates\":[{\"id\":\"01KXT44TAQSBYE98DD6FM08V34\",\"to_status\":\"id" +
        "entified\",\"message_string\":\"We have identified an issue causing some users to receive access-denied " +
        "errors when using the Codex desktop app and CLI.\",\"published_at\":\"2026-07-18T08:05:37.238Z\"}]},{\"id\"" +
        ":\"01KX7Y6ETMKP3ATQ85Z33J0EHN\",\"name\":\"Elevated Errors for Sora API\",\"status\":\"resolved\",\"published_a" +
        "t\":\"2026-07-11T06:35:19.763Z\",\"affected_components\":[{\"component_id\":\"01K9G527YRPY1EFRMHTKB5BKT5\",\"s" +
        "tatus\":\"full_outage\",\"current_status\":\"operational\"}],\"component_impacts\":[{\"id\":\"01KX7Y6ETM71JDXZG1" +
        "0HPD8XVB\",\"component_id\":\"01K9G527YRPY1EFRMHTKB5BKT5\",\"status\":\"full_outage\",\"start_at\":\"2026-07-11T" +
        "06:35:19.763Z\",\"end_at\":\"2026-07-11T07:03:51.923Z\"}],\"updates\":[{\"id\":\"01KX7Y6ETMR1WD2RHGA5M234AD\",\"" +
        "to_status\":\"investigating\",\"message_string\":\"We are investigating the issue for the listed services." +
        "\",\"published_at\":\"2026-07-11T06:35:19.763Z\"}]},{\"id\":\"01M0JXWD740S0Y50DWJZS7SH75\",\"name\":\"Unexpected" +
        " logouts for some ChatGPT web users\",\"status\":\"resolved\",\"published_at\":\"2026-08-21T19:48:34.66Z\",\"a" +
        "ffected_components\":[{\"component_id\":\"01JMXBNJXG1S2D9V65P1ZZTD94\",\"status\":\"degraded_performance\",\"c" +
        "urrent_status\":\"operational\"}],\"component_impacts\":[{\"id\":\"01M0JYA4EPG62Z3PJDDYRDQNN2\",\"component_id" +
        "\":\"01JMXBNJXG1S2D9V65P1ZZTD94\",\"status\":\"degraded_performance\",\"start_at\":\"2026-08-21T17:57:00Z\",\"en" +
        "d_at\":\"2026-08-21T20:36:33.63Z\"}],\"updates\":[{\"id\":\"01M0JXWD74Q6EHRNX9TJQQTVPK\",\"to_status\":\"investi" +
        "gating\",\"message_string\":\"We\\u2019re investigating an issue causing some ChatGPT web users to be une" +
        "xpectedly logged out when refreshing the page.\",\"published_at\":\"2026-08-21T19:48:34.66Z\"}]},{\"id\":\"0" +
        "1KXHK8YFSP8B9WP110W4XEM45\",\"name\":\"Issue affecting voice mode in ChatGPT\",\"status\":\"resolved\",\"publi" +
        "shed_at\":\"2026-07-15T00:36:51.321Z\",\"affected_components\":[{\"component_id\":\"01JMXBNJXGGT5SR5DB9J7GYY" +
        "48\",\"status\":\"full_outage\",\"current_status\":\"operational\"}],\"component_impacts\":[{\"id\":\"01KXHK8YFS5Y" +
        "20X9TG2DA9Z27F\",\"component_id\":\"01JMXBNJXGGT5SR5DB9J7GYY48\",\"status\":\"full_outage\",\"start_at\":\"2026-" +
        "07-15T00:36:51.321Z\",\"end_at\":\"2026-07-15T00:38:18.665Z\"}],\"updates\":[{\"id\":\"01KXHK8YFSF3A53MKBDQ5DF" +
        "XSZ\",\"to_status\":\"investigating\",\"message_string\":\"We are investigating the issue for the listed ser" +
        "vices.\",\"published_at\":\"2026-07-15T00:36:51.321Z\"}]}]}"
}
