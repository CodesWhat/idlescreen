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
    "w384-t0.0": 0x39be_347a_5a8b_30c4,
    "w384-t7.3": 0xa61d_6bfd_07a5_9530,
    "w384-t33.1": 0x1af8_9b33_ac03_5150,
    "w384-t61.7": 0x2cb3_2daa_2dc0_bebf,
    "w384-t100.4": 0xcdc9_db71_582f_a79d,
    "w384-t523.9": 0x3af5_af03_2b52_dd00,
    "w384-light-sunset": 0x35f5_8a90_5092_333e,
    "w384-light-moonBlue": 0x95ac_a8a3_6656_37ac,
    "w384-light-blacklight": 0x33cc_e0f7_9016_2dc5,
    "w384-light-automatic": 0x95ac_a8a3_6656_37ac,
    "w384-reduce-t0.0": 0xcbfe_7393_2c50_5d48,
    "w384-reduce-t100.4": 0xcbfe_7393_2c50_5d48,
    "w384-unfed-noequipment": 0xef4_a423_5f44_427a,
    "w384-foreground-only": 0x4950_173a_81ea_3b2c,
    "w384-no-objects": 0xc78c_7a2f_9eab_c0b4,
    "w768-t0.0": 0xa61_7d0b_9880_813d,
    "w768-t7.3": 0xf276_da76_44e1_8dfe,
    "w768-t33.1": 0xd71b_9e13_19c7_7027,
    "w768-t61.7": 0xf9a9_841e_243f_31a0,
    "w768-t100.4": 0x2d04_1424_dd80_40e4,
    "w768-t523.9": 0xe59b_aa33_b75b_1f88,
    "w768-light-sunset": 0x1c7e_ac4a_22f1_f43e,
    "w768-light-moonBlue": 0x3c11_fe51_0096_e009,
    "w768-light-blacklight": 0xa24d_11bd_2373_d4df,
    "w768-light-automatic": 0x3c11_fe51_0096_e009,
    "w768-reduce-t0.0": 0x7207_ba5a_68bc_e428,
    "w768-reduce-t100.4": 0x7207_ba5a_68bc_e428,
    "w768-unfed-noequipment": 0x35cb_cac1_e636_8226,
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
    "w384-automatic-t40000.0": 0x6629_b2cc_b819_a34d,
    "w384-automatic-t50000.0": 0x476e_2b57_3863_9585,
    "w768-automatic-t40000.0": 0x8978_dacd_e39e_7fe0,
    "w768-automatic-t50000.0": 0x8fd3_002f_c80f_95aa,
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
