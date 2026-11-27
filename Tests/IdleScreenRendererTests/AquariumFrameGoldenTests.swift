import Testing

@testable import IdleScreenRenderer

/// Pixel-equivalence goldens captured on the pre-optimization renderer. Any
/// render-cost change must reproduce these hashes bit for bit.
@Suite("Aquarium frame pixel goldens")
struct AquariumFrameGoldenTests {
  struct Case {
    let name: String
    let settings: IdleScreenAquariumRenderSettings?
    let time: Double
  }

  static let times: [Double] = [0, 7.3, 33.1, 61.7, 100.4, 523.9]

  static var cases: [Case] {
    var result: [Case] = []
    for width in AquariumFrameFixtures.widths {
      for time in times {
        result.append(
          .init(
            name: "w\(width)-t\(time)", settings: AquariumFrameFixtures.settings(width: width),
            time: time))
      }
      for light in ["sunset", "moonBlue", "blacklight", "automatic"] {
        result.append(
          .init(
            name: "w\(width)-light-\(light)",
            settings: AquariumFrameFixtures.settings(width: width, light: light), time: 61.7))
      }
      for time in [40_000.0, 50_000] {
        result.append(
          .init(
            name: "w\(width)-automatic-t\(time)",
            settings: AquariumFrameFixtures.settings(width: width, light: "automatic"),
            time: time))
      }
      for time in [0.0, 100.4] {
        result.append(
          .init(
            name: "w\(width)-reduce-t\(time)",
            settings: AquariumFrameFixtures.settings(
              width: width, light: "automatic", reduceMotion: true), time: time))
      }
      result.append(
        .init(
          name: "w\(width)-unfed-noequipment",
          settings: AquariumFrameFixtures.settings(
            width: width, equipment: [], substrate: "neonGravel", fed: false), time: 33.1))
      var foreground = AquariumFrameFixtures.settings(width: width)
      foreground.objects = foreground.objects.map {
        var item = $0
        item.foreground = true
        return item
      }
      foreground.inhabitants = []
      result.append(.init(name: "w\(width)-foreground-only", settings: foreground, time: 12.5))
      var empty = AquariumFrameFixtures.settings(width: width)
      empty.objects = []
      result.append(.init(name: "w\(width)-no-objects", settings: empty, time: 44.4))
    }
    for time in [0.0, 33.1, 100.4] {
      result.append(.init(name: "default-t\(time)", settings: nil, time: time))
    }
    return result
  }

  static let expected: [String: UInt64] = [
    "w384-t0.0": 0x862a_c787_f2c4_e7d3,
    "w384-t7.3": 0xc0d_0155_8428_688c,
    "w384-t33.1": 0x712f_81c9_2767_6340,
    "w384-t61.7": 0x964a_d672_15bb_b7c8,
    "w384-t100.4": 0x380_b240_17d6_3470,
    "w384-t523.9": 0x6317_c046_1189_4c90,
    "w384-light-sunset": 0x95e2_401f_33cd_6abe,
    "w384-light-moonBlue": 0xd068_08df_458a_be62,
    "w384-light-blacklight": 0x9dd8_8a01_687d_3f60,
    "w384-light-automatic": 0xd068_08df_458a_be62,
    "w384-reduce-t0.0": 0x3aee_0bda_d13a_8942,
    "w384-reduce-t100.4": 0x3aee_0bda_d13a_8942,
    "w384-unfed-noequipment": 0xe25d_cf70_12af_d632,
    "w384-foreground-only": 0x4950_173a_81ea_3b2c,
    "w384-no-objects": 0xc78c_7a2f_9eab_c0b4,
    "w768-t0.0": 0x8cbf_850e_26bb_99ac,
    "w768-t7.3": 0xc6dd_6377_6170_3a28,
    "w768-t33.1": 0x3fd6_5907_a174_41ab,
    "w768-t61.7": 0x20dc_e8d0_42cb_90e0,
    "w768-t100.4": 0x1a93_f042_feaf_a6c2,
    "w768-t523.9": 0xe64e_c1dc_8761_de33,
    "w768-light-sunset": 0xf7f1_0c67_dee3_9be8,
    "w768-light-moonBlue": 0xa55a_4ee2_8e3a_c251,
    "w768-light-blacklight": 0x354e_14a6_149c_13d7,
    "w768-light-automatic": 0xa55a_4ee2_8e3a_c251,
    "w768-reduce-t0.0": 0x19c4_8fd0_202c_5da3,
    "w768-reduce-t100.4": 0x19c4_8fd0_202c_5da3,
    "w768-unfed-noequipment": 0x6e45_8f4c_c191_ddea,
    "w768-foreground-only": 0x6faa_7563_6711_cb41,
    "w768-no-objects": 0xc9c6_f1a0_9e99_db5d,
    "w1152-t0.0": 0x8a76_a586_a416_b30e,
    "w1152-t7.3": 0x2c15_cc87_bdfd_dbc3,
    "w1152-t33.1": 0x6f82_1d9f_e47c_f952,
    "w1152-t61.7": 0xa479_9938_d0fd_f6ea,
    "w1152-t100.4": 0x9919_e371_ee5e_2d60,
    "w1152-t523.9": 0xecbe_ac59_6c1a_8909,
    "w1152-light-sunset": 0x3ac7_e48a_d784_ade6,
    "w1152-light-moonBlue": 0x28b4_577a_bba7_9687,
    "w1152-light-blacklight": 0xd3a4_a351_0e36_b16c,
    "w1152-light-automatic": 0x28b4_577a_bba7_9687,
    "w1152-reduce-t0.0": 0x1ae5_83f8_fa57_0533,
    "w1152-reduce-t100.4": 0x1ae5_83f8_fa57_0533,
    "w1152-unfed-noequipment": 0x4408_df3c_c384_82ad,
    "w1152-foreground-only": 0xe514_5bda_b682_fc08,
    "w1152-no-objects": 0xfda7_0f74_ce65_af77,
    "w1152-automatic-t40000.0": 0x9994_d336_f458_612a,
    "w1152-automatic-t50000.0": 0xa2d6_9a7e_ea4b_7794,
    "w384-automatic-t40000.0": 0x3caa_9f4b_093a_e31e,
    "w384-automatic-t50000.0": 0x6cf4_58ae_57fd_df18,
    "w768-automatic-t40000.0": 0xd060_1fb0_9402_6886,
    "w768-automatic-t50000.0": 0x7d75_564a_d936_0d81,
    "default-t0.0": 0xe9ba_1488_8d0a_455b,
    "default-t33.1": 0x46cf_348c_729d_0369,
    "default-t100.4": 0x382a_34d9_0368_282b,
  ]

  @Test func framesMatchTheCapturedGoldens() {
    var mismatches: [String] = []
    for item in Self.cases {
      let hash = AquariumFrameFixtures.hash(
        IdleScreenAquarium.frame(at: item.time, seed: 42, settings: item.settings))
      if Self.expected[item.name] != hash {
        mismatches.append("\(item.name) \(String(hash, radix: 16))")
      }
    }
    #expect(mismatches.isEmpty, "pixel drift in \(mismatches)")
  }
}
