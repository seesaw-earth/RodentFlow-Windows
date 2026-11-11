// SessionModels.swift — what is stored for one analysis session (session.json).
// Decoding is tolerant: missing keys fall back to defaults, so files from older / newer builds open.

import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value if present and valid, otherwise returns the default.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - Calibration

struct ArenaCalibration: Codable, Equatable {
    var kind: ArenaKind = .rectangle
    /// Rectangle corners in order TL, TR, BR, BL (normalized image coordinates).
    var corners: [NPoint] = [NPoint(0.1, 0.1), NPoint(0.9, 0.1), NPoint(0.9, 0.9), NPoint(0.1, 0.9)]
    var widthCM: Double = 40
    var heightCM: Double = 40
    var circleCenter = NPoint(0.5, 0.5)
    var circleEdge = NPoint(0.85, 0.5)
    var diameterCM: Double = 40
    /// Maze handles: plus C,N,E,S,W · Y J,A,B,C · T J,S,L,R.
    var mazePoints: [NPoint] = []
    var armWidthCM: Double = 5
    var armLengthCM: Double = 30
    /// Paradigm markers (objects, cups, shelter, target hole, cue card).
    var markers: [String: NPoint] = [:]
    /// Width of a ring-shaped track on a circle calibration (elevated zero maze), cm; 0 = a full disc.
    var ringWidthCM: Double = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case kind, corners, widthCM, heightCM, circleCenter, circleEdge, diameterCM, mazePoints, armWidthCM, armLengthCM, markers
        case ringWidthCM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArenaCalibration()
        kind = c.v(.kind, d.kind)
        corners = c.v(.corners, d.corners)
        if corners.count != 4 { corners = d.corners }
        widthCM = c.v(.widthCM, d.widthCM)
        heightCM = c.v(.heightCM, d.heightCM)
        circleCenter = c.v(.circleCenter, d.circleCenter)
        circleEdge = c.v(.circleEdge, d.circleEdge)
        diameterCM = c.v(.diameterCM, d.diameterCM)
        mazePoints = c.v(.mazePoints, d.mazePoints)
        armWidthCM = c.v(.armWidthCM, d.armWidthCM)
        armLengthCM = c.v(.armLengthCM, d.armLengthCM)
        markers = c.v(.markers, d.markers)
        ringWidthCM = max(0, c.v(.ringWidthCM, d.ringWidthCM))
    }

    /// A marker's position; a marker added in a later version (the looming threat zone, RodentFlow 2.1) that an older
    /// session does not have yet starts at its default place in the arena.
    func marker(_ key: String, mapping: ArenaMapping) -> NPoint? {
        if let p = markers[key] { return p }
        let e = mapping.extent
        switch key {
        case "threat": return mapping.toNormalized(V2(0.6 * e.x, 0.6 * e.y)).clamped()
        default: return nil
        }
    }

    /// Inner radius of the ring track (cm) on a circle calibration with a track width; nil for a full disc.
    var ringInnerRadiusCM: Double? {
        guard kind == .circle, ringWidthCM > 0 else { return nil }
        let r = max(diameterCM, 1) / 2
        return max(0, r - min(ringWidthCM, r * 0.9))
    }

    /// Default handles for a paradigm, laid out for a frame of the given pixel size.
    static func makeDefault(paradigm: Paradigm, kind: ArenaKind, frameSize: V2) -> ArenaCalibration {
        var cal = ArenaCalibration()
        cal.kind = kind
        let w = max(frameSize.x, 1), h = max(frameSize.y, 1)
        let size = paradigm.defaultArenaSize
        let minDim = min(w, h)

        switch kind {
        case .none:
            break
        case .rectangle:
            cal.widthCM = size.width
            cal.heightCM = size.height
            let aspect = size.width / max(size.height, 1)
            var rectH = 0.8 * h
            var rectW = aspect * rectH
            if rectW > 0.85 * w {
                let s = 0.85 * w / rectW
                rectW *= s
                rectH *= s
            }
            let nw = rectW / w / 2, nh = rectH / h / 2
            cal.corners = [NPoint(0.5 - nw, 0.5 - nh), NPoint(0.5 + nw, 0.5 - nh), NPoint(0.5 + nw, 0.5 + nh), NPoint(0.5 - nw, 0.5 + nh)]
        case .circle:
            cal.diameterCM = size.width
            let r = 0.42 * minDim
            cal.circleCenter = NPoint(0.5, 0.5)
            cal.circleEdge = NPoint(0.5 + r / w, 0.5)
            if paradigm == .elevatedZeroMaze { cal.ringWidthCM = size.height }
        case .plusMaze:
            cal.armLengthCM = size.width
            cal.armWidthCM = size.height
            let l = 0.44 * minDim
            cal.mazePoints = [NPoint(0.5, 0.5), NPoint(0.5, 0.5 - l / h), NPoint(0.5 + l / w, 0.5), NPoint(0.5, 0.5 + l / h), NPoint(0.5 - l / w, 0.5)]
        case .yMaze:
            cal.armLengthCM = size.width
            cal.armWidthCM = size.height
            let l = 0.42 * minDim
            let jy = 0.56
            cal.mazePoints = [NPoint(0.5, jy), NPoint(0.5, jy - l / h),
                              NPoint(0.5 - 0.866 * l / w, jy + 0.5 * l / h), NPoint(0.5 + 0.866 * l / w, jy + 0.5 * l / h)]
        case .tMaze:
            cal.armLengthCM = size.width
            cal.armWidthCM = size.height
            let l = 0.45 * minDim
            let jy = 0.28
            cal.mazePoints = [NPoint(0.5, jy), NPoint(0.5, jy + 1.3 * l / h), NPoint(0.5 - l / w, jy), NPoint(0.5 + l / w, jy)]
        }

        // Markers: positions defined in arena units, converted to the image with the default mapping.
        let mapping = ArenaMapper.mapping(cal, frameSize: frameSize)
        let e = mapping.extent
        func put(_ key: String, _ ax: Double, _ ay: Double) {
            cal.markers[key] = mapping.toNormalized(V2(ax * e.x, ay * e.y)).clamped()
        }
        switch paradigm {
        case .threeChamber:
            put("cupL", 1.0 / 6.0, 0.5)
            put("cupR", 5.0 / 6.0, 0.5)
        case .novelObject:
            put("objA", 0.3, 0.3)
            put("objB", 0.7, 0.3)
        case .headDirection:
            put("cue", 0.5, 0.02)
        case .barnesMaze:
            // Target hole on the ring ~5 cm from the edge, at 45° (upper right).
            let r = e.x / 2
            let ring = max(r - 5, r * 0.8)
            let a = 45.0 * Double.pi / 180
            cal.markers["target"] = mapping.toNormalized(V2(r + ring * cos(a), r - ring * sin(a))).clamped()
        case .waterMaze:
            // Platform in the middle of the upper-right quadrant (half-way between center and wall).
            let r = e.x / 2
            let a = 45.0 * Double.pi / 180
            cal.markers["platform"] = mapping.toNormalized(V2(r + 0.5 * r * cos(a), r - 0.5 * r * sin(a))).clamped()
        case .elevatedZeroMaze:
            // Middle of the track at the top of the frame: the open segment centered there.
            if kind == .circle {
                let r = e.x / 2
                let half = min(cal.ringWidthCM, r * 0.9) / 2
                cal.markers["open"] = mapping.toNormalized(V2(r, half)).clamped()
            }
        case .noveltySuppressedFeeding:
            put("food", 0.5, 0.5)
        case .looming:
            put("shelter", 0.16, 0.16)
            put("threat", 0.6, 0.6)
        case .platformAvoidance:
            // Platform in a corner, reward port on the opposite wall (shown only when the reward zone is used).
            put("platform", 0.22, 0.28)
            put("reward", 0.95, 0.5)
        case .stepDown:
            put("platform", 0.5, 0.5)
        case .marbleBurying:
            // Centers of the four corner marbles of the grid (top-left, top-right, bottom-right, bottom-left).
            put("g1", 0.15, 0.18)
            put("g2", 0.85, 0.18)
            put("g3", 0.85, 0.82)
            put("g4", 0.15, 0.82)
        default:
            break
        }
        return cal
    }
}

// MARK: - Inference settings (changing these requires re-running the model)

struct InferenceSettings: Codable, Equatable {
    var stride: Int = 1
    var grayscale = true
    var animalCount = 1
    var startTime: Double = 0
    /// 0 = until the end of the video.
    var endTime: Double = 0
    /// Track only the calibrated arena (+ margin) or the whole frame (ArenaROI.swift).
    /// New analyses track the arena; files from before 2.0 decode as `.fullFrame`.
    var region: TrackingRegion = .arena
    /// Margin around the arena as a fraction of its larger side in the image.
    var arenaMargin: Double = ArenaROI.defaultMargin
    /// The region that was actually tracked (normalized upright frame), recorded when a run starts.
    /// nil = whole frame. Only meaningful in `Session.usedInference`.
    var roi: NRect?
    /// Coat colour of the animals: chooses the pose model (PoseModels.swift). Files from before iOS build 19 /
    /// Mac build 15 decode as dark (the models they were tracked with).
    var coat: CoatColor = .dark

    init() {}

    enum CodingKeys: String, CodingKey { case stride, grayscale, animalCount, startTime, endTime, region, arenaMargin, roi, coat }
    /// iOS build 18 (white-mouse test build) stored the model choice as `poseModel` ("whiteMouse").
    private enum LegacyKeys: String, CodingKey { case poseModel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stride = max(1, c.v(.stride, 1))
        grayscale = c.v(.grayscale, true)
        animalCount = min(kGroupMaxAnimals, max(1, c.v(.animalCount, 1)))
        startTime = c.v(.startTime, 0)
        endTime = c.v(.endTime, 0)
        region = c.v(.region, .fullFrame)
        arenaMargin = min(0.5, max(0, c.v(.arenaMargin, ArenaROI.defaultMargin)))
        roi = c.v(.roi, nil as NRect?)
        var stored = c.v(.coat, CoatColor.dark)
        if (try? c.decodeIfPresent(String.self, forKey: .coat)) == nil,
           let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let choice = (try? legacy.decodeIfPresent(String.self, forKey: .poseModel)) ?? nil,
           choice.lowercased().contains("white") {
            stored = .white
        }
        coat = stored.valid(for: animalCount)
    }

    /// Pose model a run with these settings uses.
    var modelName: String { PoseModels.name(for: self) }

    /// Settings that require a new recognition run when changed (the recorded `roi` is compared
    /// separately, against the current calibration).
    func sameModelSettings(as o: InferenceSettings) -> Bool {
        stride == o.stride && grayscale == o.grayscale && animalCount == o.animalCount
            && coat.valid(for: animalCount) == o.coat.valid(for: o.animalCount)
            && abs(startTime - o.startTime) <= 0.01 && abs(endTime - o.endTime) <= 0.01
            && region == o.region && (region == .fullFrame || abs(arenaMargin - o.arenaMargin) < 1e-6)
    }
}

// MARK: - Analysis parameters (changing these only recomputes, no re-inference)

struct AnalysisParams: Codable, Equatable {
    // Preprocessing
    var kpConf: Double = 0.5
    var smoothing: Double = 0.15
    var maxGap: Double = 0.5
    var maxJumpSpeed: Double = 150
    // Analysis window (seconds of video time); length 0 = to the end
    var windowStart: Double = 0
    var windowLength: Double = 0
    var timeBin: Double = 60
    // Locomotion / immobility
    var moveSpeed: Double = 2
    var freezeSpeed: Double = 1.0
    var freezeMin: Double = 1.0
    // Open field
    var centerFraction: Double = 0.5
    /// Side of each of the four corner zones (open field, rectangular arena), as a fraction of the arena's shorter side;
    /// nil = the default (ZoneBuilder.defaultCornerFraction, 25 %: the four corner squares of a 4 × 4 grid). Optional so
    /// that it is not written until it is set: setups saved before keep their encoding (the Mac's summary cache keys).
    var cornerFraction: Double? = nil
    // Objects (NOR) and cups (three-chamber)
    var objectRadius: Double = 2.5
    var exploreMargin: Double = 2
    var headTolerance: Double = 45
    var novelObject = "B"
    var cupRadius: Double = 5
    var stimSide = "L"
    var centerChamberFraction: Double = 1.0 / 3.0
    /// Offset of the middle chamber center from 0.5 of the arena width (0 = centered).
    var centerChamberOffset: Double = 0
    // Social interaction test (CSDS)
    var enclosureWall = "top"
    var enclosureWidth: Double = 10
    var enclosureDepth: Double = 6.5
    var izWidth: Double = 26
    var izDepth: Double = 14
    var cornerSize: Double = 9
    // Dyadic social
    var noseNoseDist: Double = 2.5
    var anogenitalDist: Double = 2.5
    var bodySniffDist: Double = 3
    var proximityDist: Double = 10
    var followDist: Double = 15
    var followSpeed: Double = 5
    var followAngle: Double = 45
    var followMin: Double = 0.5
    // Group behaviour (body lengths and BL/s; AnalyzersGroup.swift)
    var groupContactBL: Double = 0.35
    var groupNoseBL: Double = 0.3
    var groupApproachSpeed: Double = 0.6
    var groupApproachDist: Double = 2.5
    var groupApproachMin: Double = 0.4
    var groupChaseSpeed: Double = 2.7
    var groupChaseMin: Double = 0.3
    // Plus / Y / T maze
    var openAxis = "NS"
    var entryRule = "full"     // body · full · nose
    var headDipReach: Double = 6
    var headDipMin: Double = 0.2
    var sapElongation: Double = 1.2
    var sapSpeed: Double = 5
    var sapMin: Double = 0.5
    var choiceRadiusFactor: Double = 1.0
    var vteZ: Double = 0.5
    // Light–dark
    var lightOnLeft = true
    var lightFraction: Double = 2.0 / 3.0
    var pokeMin: Double = 0.2
    // Barnes
    var holeCount: Int = 20
    var holeRadius: Double = 2.5
    var pokeMargin: Double = 1.0
    var holePokeMin: Double = 0.15
    // Fear conditioning
    var csOnsets: [Double] = []
    var csDuration: Double = 30
    // Looming
    var stimOnsets: [Double] = []
    var shelterRadius: Double = 10
    var flightFactor: Double = 4
    var flightMinSpeed: Double = 15
    var escapeWindow: Double = 10
    var baselineWindow: Double = 5
    // Rotation
    var lesionSide = "none"    // none · left · right
    var cameraBelow = false
    var rotationBin: Double = 300
    // Head direction / spatial
    var hdBinDeg: Double = 6
    var hdReference = "image"  // image · cue
    var hdMinBinTime: Double = 1
    var spatialBin: Double = 2.5
    var coverageMinTime: Double = 0.2
    // Resident–intruder (aggression); distances in body lengths (BL = neck → tail base), speeds in BL/s
    var riResident = "auto"        // auto · A · B
    var riIntruderEntry: Double = 0    // video time (s); 0 = detect automatically
    var riDuration: Double = 600       // test length from the entry (s); 0 = to the end
    var riCloseDist: Double = 1.2
    var riFightSpeed: Double = 2.0
    var riFightTurn: Double = 250
    var riFightMin: Double = 0.3
    var riClinchMin: Double = 1.0
    var riChaseSpeed: Double = 2.7
    var riChaseMin: Double = 0.3
    var riKeepDownMin: Double = 1.0
    var riMountMin: Double = 1.0
    var riThreatMin: Double = 0.3
    var riUprightRatio: Double = 0.65
    var riSniffDist: Double = 0.4
    // Morris water maze (cm, s, cm/s, °)
    var mwmPlatformDiameter: Double = 10
    var mwmPlatformMargin: Double = 2
    var mwmEscapeStay: Double = 1
    var mwmZoneRadius: Double = 10
    var mwmWallZone: Double = 6
    var mwmFloatSpeed: Double = 2
    var mwmFloatMin: Double = 1
    var mwmCorridor: Double = 40
    // Place preference (RTPP / CPP): paired side L / R, divider position (fraction of the width), middle zone
    var ppPairedSide = "R"
    var ppSplit: Double = 0.5
    var ppMiddle = false
    var ppMiddleFraction: Double = 0.2
    var ppRule = "body"       // body · full (body center and tail base)
    // Elevated zero maze (iOS build 15, Mac build 14): head dip = nose beyond the inner / outer edge by ≥ this (cm)
    var ezmDipBeyond: Double = 1
    // Novelty-suppressed feeding: food zone radius (cm); candidate feeding = nose in the zone, body slower than
    // nsfStillSpeed (cm/s) for ≥ nsfStillMin (s). The first bite is confirmed in the review: nsfFeedingTime = its
    // video time (s; < 0 = not confirmed) or nsfNoFeeding = no bite before the cut-off.
    var nsfFoodRadius: Double = 3
    var nsfStillSpeed: Double = 2
    var nsfStillMin: Double = 3
    var nsfFeedingTime: Double = -1
    var nsfNoFeeding = false
    // Hunger control entered by hand (g; < 0 = not entered): home-cage food in 5 min, weight before the fast and on the test day.
    var nsfHomeCageFood: Double = -1
    var nsfWeightBefore: Double = -1
    var nsfWeightTest: Double = -1
    // Platform-mediated avoidance (RodentFlow 2.1): platform size (cm) around the P handle; on the platform when
    // the body center (body), the nose and neck (front, ≈ front paws) or the body center and tail base (full) are on it.
    // Optional reward-port zone around the R handle (nose within the radius).
    var pmaPlatformWidth: Double = 10
    var pmaPlatformHeight: Double = 10
    var pmaRule = "body"
    var pmaReward = false
    var pmaRewardRadius: Double = 3
    // Visual cliff (2.1): deep side, center board position and width (fractions of the arena length), side-change
    // rule as in place preference, early window (s) reported separately, minimum edge head-dip duration (s).
    var vcDeepSide = "R"
    var vcSplit: Double = 0.5
    var vcCenterFraction: Double = 0.2
    var vcRule = "full"
    var vcEarly: Double = 240
    var vcDipMin: Double = 0.2
    // Step-down inhibitory avoidance (2.1): platform size (cm) around the P handle; stepped down when the body
    // center (body) or the body center and the tail base (full, ≈ four paws) are off it; minimum edge head-dip (s).
    var sdPlatformWidth: Double = 7
    var sdPlatformHeight: Double = 7
    var sdRule = "full"
    var sdDipMin: Double = 0.2
    // Marble burying (2.1): grid of marbles between the four corner handles, marble diameter (cm), "covered"
    // threshold (fraction of the visible marble area), sampling interval (s), wait after the mouse leaves a marble (s),
    // approach distance from the marble's edge (cm).
    var mbRows: Int = 4
    var mbCols: Int = 5
    var mbDiameter: Double = 1.6
    var mbThreshold: Double = 0.67
    var mbSampleInterval: Double = 0.5
    var mbLeaveWait: Double = 1
    var mbApproach: Double = 1
    // Looming (2.1): freezing as in fear conditioning (motion) or body speed below a threshold (speed, De Franceschi
    // et al. 2016: < 2 cm/s for ≥ 0.5 s); optional threat zone around the T handle.
    var loomFreezeRule = "motion"
    var loomFreezeSpeed: Double = 2
    var loomFreezeMin: Double = 0.5
    var loomThreat = false
    var loomThreatRadius: Double = 10

    init() {}

    /// The first bite has been confirmed (a time, or no bite before the cut-off).
    var nsfConfirmed: Bool { nsfNoFeeding || nsfFeedingTime >= 0 }

    static func defaults(for paradigm: Paradigm) -> AnalysisParams {
        var p = AnalysisParams()
        switch paradigm {
        case .socialInteraction: p.windowLength = 150
        case .elevatedPlusMaze: p.windowLength = 300
        case .rotation: p.timeBin = 300
        case .headDirection: p.hdReference = "image"
        case .waterMaze:
            // One trial: release → at most 60 s; probe bins of 15 s.
            p.windowLength = 60
            p.timeBin = 15
        case .passiveAvoidance:
            // Cut-off of the test; equal compartments; four-paw entry approximated by body center + tail base.
            p.windowLength = 300
            p.lightFraction = 0.5
            p.entryRule = "full"
        case .placePreference:
            p.timeBin = 300
        case .elevatedZeroMaze:
            // 5 min test; four-paw entry approximated by body center + tail base; finer heat map for a 5 cm track.
            p.windowLength = 300
            p.entryRule = "full"
            p.spatialBin = 1.5
        case .noveltySuppressedFeeding:
            // 10 min cut-off (Samuels & Hen 2011); one-minute bins.
            p.windowLength = 600
            p.centerFraction = 0.5
        case .residentIntruder:
            // Lunges last 100–200 ms: light smoothing, short gap filling.
            p.smoothing = 0.07
            p.maxGap = 0.2
        case .platformAvoidance:
            p.timeBin = 60
        case .stepDown:
            // Test cut-off (training is often 60 s); four-paw step-down approximated by body center + tail base.
            p.windowLength = 300
        case .visualCliff:
            p.timeBin = 60
        case .marbleBurying:
            // 30 min test, 5 min bins.
            p.windowLength = 1800
            p.timeBin = 300
        default: break
        }
        return p
    }

    enum CodingKeys: String, CodingKey {
        case kpConf, smoothing, maxGap, maxJumpSpeed, windowStart, windowLength, timeBin, moveSpeed, freezeSpeed, freezeMin
        case centerFraction, cornerFraction, objectRadius, exploreMargin, headTolerance, novelObject, cupRadius, stimSide, centerChamberFraction, centerChamberOffset
        case enclosureWall, enclosureWidth, enclosureDepth, izWidth, izDepth, cornerSize
        case noseNoseDist, anogenitalDist, bodySniffDist, proximityDist, followDist, followSpeed, followAngle, followMin
        case groupContactBL, groupNoseBL, groupApproachSpeed, groupApproachDist, groupApproachMin, groupChaseSpeed, groupChaseMin
        case openAxis, entryRule, headDipReach, headDipMin, sapElongation, sapSpeed, sapMin, choiceRadiusFactor, vteZ
        case lightOnLeft, lightFraction, pokeMin, holeCount, holeRadius, pokeMargin, holePokeMin
        case csOnsets, csDuration, stimOnsets, shelterRadius, flightFactor, flightMinSpeed, escapeWindow, baselineWindow
        case lesionSide, cameraBelow, rotationBin, hdBinDeg, hdReference, hdMinBinTime, spatialBin, coverageMinTime
        case riResident, riIntruderEntry, riDuration, riCloseDist, riFightSpeed, riFightTurn, riFightMin
        case riClinchMin, riChaseSpeed, riChaseMin, riKeepDownMin, riMountMin, riThreatMin, riUprightRatio, riSniffDist
        case mwmPlatformDiameter, mwmPlatformMargin, mwmEscapeStay, mwmZoneRadius, mwmWallZone, mwmFloatSpeed, mwmFloatMin, mwmCorridor
        case ppPairedSide, ppSplit, ppMiddle, ppMiddleFraction, ppRule
        case ezmDipBeyond, nsfFoodRadius, nsfStillSpeed, nsfStillMin, nsfFeedingTime, nsfNoFeeding
        case nsfHomeCageFood, nsfWeightBefore, nsfWeightTest
        case pmaPlatformWidth, pmaPlatformHeight, pmaRule, pmaReward, pmaRewardRadius
        case vcDeepSide, vcSplit, vcCenterFraction, vcRule, vcEarly, vcDipMin
        case sdPlatformWidth, sdPlatformHeight, sdRule, sdDipMin
        case mbRows, mbCols, mbDiameter, mbThreshold, mbSampleInterval, mbLeaveWait, mbApproach
        case loomFreezeRule, loomFreezeSpeed, loomFreezeMin, loomThreat, loomThreatRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnalysisParams()
        kpConf = c.v(.kpConf, d.kpConf)
        smoothing = c.v(.smoothing, d.smoothing)
        maxGap = c.v(.maxGap, d.maxGap)
        maxJumpSpeed = c.v(.maxJumpSpeed, d.maxJumpSpeed)
        windowStart = c.v(.windowStart, d.windowStart)
        windowLength = c.v(.windowLength, d.windowLength)
        timeBin = c.v(.timeBin, d.timeBin)
        moveSpeed = c.v(.moveSpeed, d.moveSpeed)
        freezeSpeed = c.v(.freezeSpeed, d.freezeSpeed)
        freezeMin = c.v(.freezeMin, d.freezeMin)
        centerFraction = c.v(.centerFraction, d.centerFraction)
        cornerFraction = (try? c.decodeIfPresent(Double.self, forKey: .cornerFraction)) ?? nil
        objectRadius = c.v(.objectRadius, d.objectRadius)
        exploreMargin = c.v(.exploreMargin, d.exploreMargin)
        headTolerance = c.v(.headTolerance, d.headTolerance)
        novelObject = c.v(.novelObject, d.novelObject)
        cupRadius = c.v(.cupRadius, d.cupRadius)
        stimSide = c.v(.stimSide, d.stimSide)
        centerChamberFraction = c.v(.centerChamberFraction, d.centerChamberFraction)
        centerChamberOffset = c.v(.centerChamberOffset, d.centerChamberOffset)
        enclosureWall = c.v(.enclosureWall, d.enclosureWall)
        enclosureWidth = c.v(.enclosureWidth, d.enclosureWidth)
        enclosureDepth = c.v(.enclosureDepth, d.enclosureDepth)
        izWidth = c.v(.izWidth, d.izWidth)
        izDepth = c.v(.izDepth, d.izDepth)
        cornerSize = c.v(.cornerSize, d.cornerSize)
        noseNoseDist = c.v(.noseNoseDist, d.noseNoseDist)
        anogenitalDist = c.v(.anogenitalDist, d.anogenitalDist)
        bodySniffDist = c.v(.bodySniffDist, d.bodySniffDist)
        proximityDist = c.v(.proximityDist, d.proximityDist)
        followDist = c.v(.followDist, d.followDist)
        followSpeed = c.v(.followSpeed, d.followSpeed)
        followAngle = c.v(.followAngle, d.followAngle)
        followMin = c.v(.followMin, d.followMin)
        groupContactBL = c.v(.groupContactBL, d.groupContactBL)
        groupNoseBL = c.v(.groupNoseBL, d.groupNoseBL)
        groupApproachSpeed = c.v(.groupApproachSpeed, d.groupApproachSpeed)
        groupApproachDist = c.v(.groupApproachDist, d.groupApproachDist)
        groupApproachMin = c.v(.groupApproachMin, d.groupApproachMin)
        groupChaseSpeed = c.v(.groupChaseSpeed, d.groupChaseSpeed)
        groupChaseMin = c.v(.groupChaseMin, d.groupChaseMin)
        openAxis = c.v(.openAxis, d.openAxis)
        entryRule = c.v(.entryRule, d.entryRule)
        headDipReach = c.v(.headDipReach, d.headDipReach)
        headDipMin = c.v(.headDipMin, d.headDipMin)
        sapElongation = c.v(.sapElongation, d.sapElongation)
        sapSpeed = c.v(.sapSpeed, d.sapSpeed)
        sapMin = c.v(.sapMin, d.sapMin)
        choiceRadiusFactor = c.v(.choiceRadiusFactor, d.choiceRadiusFactor)
        vteZ = c.v(.vteZ, d.vteZ)
        lightOnLeft = c.v(.lightOnLeft, d.lightOnLeft)
        lightFraction = c.v(.lightFraction, d.lightFraction)
        pokeMin = c.v(.pokeMin, d.pokeMin)
        holeCount = c.v(.holeCount, d.holeCount)
        holeRadius = c.v(.holeRadius, d.holeRadius)
        pokeMargin = c.v(.pokeMargin, d.pokeMargin)
        holePokeMin = c.v(.holePokeMin, d.holePokeMin)
        csOnsets = c.v(.csOnsets, d.csOnsets)
        csDuration = c.v(.csDuration, d.csDuration)
        stimOnsets = c.v(.stimOnsets, d.stimOnsets)
        shelterRadius = c.v(.shelterRadius, d.shelterRadius)
        flightFactor = c.v(.flightFactor, d.flightFactor)
        flightMinSpeed = c.v(.flightMinSpeed, d.flightMinSpeed)
        escapeWindow = c.v(.escapeWindow, d.escapeWindow)
        baselineWindow = c.v(.baselineWindow, d.baselineWindow)
        lesionSide = c.v(.lesionSide, d.lesionSide)
        cameraBelow = c.v(.cameraBelow, d.cameraBelow)
        rotationBin = c.v(.rotationBin, d.rotationBin)
        hdBinDeg = c.v(.hdBinDeg, d.hdBinDeg)
        hdReference = c.v(.hdReference, d.hdReference)
        hdMinBinTime = c.v(.hdMinBinTime, d.hdMinBinTime)
        spatialBin = c.v(.spatialBin, d.spatialBin)
        coverageMinTime = c.v(.coverageMinTime, d.coverageMinTime)
        riResident = c.v(.riResident, d.riResident)
        riIntruderEntry = c.v(.riIntruderEntry, d.riIntruderEntry)
        riDuration = c.v(.riDuration, d.riDuration)
        riCloseDist = c.v(.riCloseDist, d.riCloseDist)
        riFightSpeed = c.v(.riFightSpeed, d.riFightSpeed)
        riFightTurn = c.v(.riFightTurn, d.riFightTurn)
        riFightMin = c.v(.riFightMin, d.riFightMin)
        riClinchMin = c.v(.riClinchMin, d.riClinchMin)
        riChaseSpeed = c.v(.riChaseSpeed, d.riChaseSpeed)
        riChaseMin = c.v(.riChaseMin, d.riChaseMin)
        riKeepDownMin = c.v(.riKeepDownMin, d.riKeepDownMin)
        riMountMin = c.v(.riMountMin, d.riMountMin)
        riThreatMin = c.v(.riThreatMin, d.riThreatMin)
        riUprightRatio = c.v(.riUprightRatio, d.riUprightRatio)
        riSniffDist = c.v(.riSniffDist, d.riSniffDist)
        mwmPlatformDiameter = c.v(.mwmPlatformDiameter, d.mwmPlatformDiameter)
        mwmPlatformMargin = c.v(.mwmPlatformMargin, d.mwmPlatformMargin)
        mwmEscapeStay = c.v(.mwmEscapeStay, d.mwmEscapeStay)
        mwmZoneRadius = c.v(.mwmZoneRadius, d.mwmZoneRadius)
        mwmWallZone = c.v(.mwmWallZone, d.mwmWallZone)
        mwmFloatSpeed = c.v(.mwmFloatSpeed, d.mwmFloatSpeed)
        mwmFloatMin = c.v(.mwmFloatMin, d.mwmFloatMin)
        mwmCorridor = c.v(.mwmCorridor, d.mwmCorridor)
        ppPairedSide = c.v(.ppPairedSide, d.ppPairedSide)
        ppSplit = c.v(.ppSplit, d.ppSplit)
        ppMiddle = c.v(.ppMiddle, d.ppMiddle)
        ppMiddleFraction = c.v(.ppMiddleFraction, d.ppMiddleFraction)
        ppRule = c.v(.ppRule, d.ppRule)
        ezmDipBeyond = c.v(.ezmDipBeyond, d.ezmDipBeyond)
        nsfFoodRadius = c.v(.nsfFoodRadius, d.nsfFoodRadius)
        nsfStillSpeed = c.v(.nsfStillSpeed, d.nsfStillSpeed)
        nsfStillMin = c.v(.nsfStillMin, d.nsfStillMin)
        nsfFeedingTime = c.v(.nsfFeedingTime, d.nsfFeedingTime)
        nsfNoFeeding = c.v(.nsfNoFeeding, d.nsfNoFeeding)
        nsfHomeCageFood = c.v(.nsfHomeCageFood, d.nsfHomeCageFood)
        nsfWeightBefore = c.v(.nsfWeightBefore, d.nsfWeightBefore)
        nsfWeightTest = c.v(.nsfWeightTest, d.nsfWeightTest)
        pmaPlatformWidth = c.v(.pmaPlatformWidth, d.pmaPlatformWidth)
        pmaPlatformHeight = c.v(.pmaPlatformHeight, d.pmaPlatformHeight)
        pmaRule = c.v(.pmaRule, d.pmaRule)
        pmaReward = c.v(.pmaReward, d.pmaReward)
        pmaRewardRadius = c.v(.pmaRewardRadius, d.pmaRewardRadius)
        vcDeepSide = c.v(.vcDeepSide, d.vcDeepSide)
        vcSplit = c.v(.vcSplit, d.vcSplit)
        vcCenterFraction = c.v(.vcCenterFraction, d.vcCenterFraction)
        vcRule = c.v(.vcRule, d.vcRule)
        vcEarly = c.v(.vcEarly, d.vcEarly)
        vcDipMin = c.v(.vcDipMin, d.vcDipMin)
        sdPlatformWidth = c.v(.sdPlatformWidth, d.sdPlatformWidth)
        sdPlatformHeight = c.v(.sdPlatformHeight, d.sdPlatformHeight)
        sdRule = c.v(.sdRule, d.sdRule)
        sdDipMin = c.v(.sdDipMin, d.sdDipMin)
        mbRows = max(1, c.v(.mbRows, d.mbRows))
        mbCols = max(1, c.v(.mbCols, d.mbCols))
        mbDiameter = c.v(.mbDiameter, d.mbDiameter)
        mbThreshold = c.v(.mbThreshold, d.mbThreshold)
        mbSampleInterval = c.v(.mbSampleInterval, d.mbSampleInterval)
        mbLeaveWait = c.v(.mbLeaveWait, d.mbLeaveWait)
        mbApproach = c.v(.mbApproach, d.mbApproach)
        loomFreezeRule = c.v(.loomFreezeRule, d.loomFreezeRule)
        loomFreezeSpeed = c.v(.loomFreezeSpeed, d.loomFreezeSpeed)
        loomFreezeMin = c.v(.loomFreezeMin, d.loomFreezeMin)
        loomThreat = c.v(.loomThreat, d.loomThreat)
        loomThreatRadius = c.v(.loomThreatRadius, d.loomThreatRadius)
    }
}

// MARK: - Video and pose summaries

struct VideoMeta: Codable, Equatable {
    var duration: Double = 0
    var fps: Double = 30
    /// Upright (display-oriented) frame size in pixels.
    var width: Double = 1920
    var height: Double = 1080
    var creationDate: Date?
    var fileSize: Int64 = 0

    var frameSize: V2 { V2(width, height) }
    var estimatedFrames: Int { Int((duration * max(fps, 1)).rounded()) }

    init() {}

    enum CodingKeys: String, CodingKey { case duration, fps, width, height, creationDate, fileSize }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = c.v(.duration, 0)
        fps = c.v(.fps, 30)
        width = c.v(.width, 1920)
        height = c.v(.height, 1080)
        creationDate = c.v(.creationDate, nil as Date?)
        fileSize = c.v(.fileSize, 0)
    }
}

struct PoseSummary: Codable, Equatable {
    var frames = 0
    var detectedFrames = 0
    var meanConfidence: Double = 0
    var msPerFrame: Double = 0
    var processedUntil: Double = 0
    var complete = false
    var animalCount = 1

    var detectionRate: Double { frames > 0 ? Double(detectedFrames) / Double(frames) : 0 }

    init() {}

    enum CodingKeys: String, CodingKey { case frames, detectedFrames, meanConfidence, msPerFrame, processedUntil, complete, animalCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frames = c.v(.frames, 0)
        detectedFrames = c.v(.detectedFrames, 0)
        meanConfidence = c.v(.meanConfidence, 0)
        msPerFrame = c.v(.msPerFrame, 0)
        processedUntil = c.v(.processedUntil, 0)
        complete = c.v(.complete, false)
        animalCount = c.v(.animalCount, 1)
    }
}

enum SessionStatus: String, Codable {
    case draft, processing, paused, done, failed

    var title: String {
        switch self {
        case .draft: return L10n.tr("待识别")
        case .processing: return L10n.tr("识别中")
        case .paused: return L10n.tr("已暂停")
        case .done: return L10n.tr("已完成")
        case .failed: return L10n.tr("失败")
        }
    }

    var symbol: String {
        switch self {
        case .draft: return "circle.dashed"
        case .processing: return "hourglass"
        case .paused: return "pause.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Session

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var paradigm: Paradigm = .openField
    var subjectID = ""
    var group = ""
    var sex = ""          // "", "M", "F"
    var phase = ""        // stored English key (see Paradigm.phases)
    var day: Int?
    var trial: Int?
    var notes = ""
    var videoName = ""
    /// File name of the video inside the session folder; nil when the copy was deleted.
    var videoFile: String?
    var video = VideoMeta()
    var calibration = ArenaCalibration()
    var calibrationTime: Double = 0
    var params = AnalysisParams()
    var inference = InferenceSettings()
    /// Inference settings of the stored pose data (nil before the first run).
    var usedInference: InferenceSettings?
    /// Pose model of the stored pose data (nil: data from before the two-animal model, i.e. kModelName).
    var usedModel: String?
    var status: SessionStatus = .draft
    var pose: PoseSummary?
    /// Cached headline metrics for lists and summary exports.
    var metrics: [String: Double] = [:]
    var metricOrder: [String] = []
    var metricLabels: [String: String] = [:]
    /// Headline metric as shown in lists, e.g. "0.42" / "35.2 %".
    var primaryTitle = ""
    var primaryDisplay = ""
    /// Every measure of the last analysis with names in both languages, units and decimals (group
    /// comparison on the phone, and the phone's own numbers sent to the Mac).
    var metricEntries: [SessionMetricEntry] = []
    /// Analyzer.metricsVersion of `metricEntries` / `metricSeries` (0 = saved before RodentFlow 2.1 build 23): older
    /// entries are recomputed from the saved pose data when the definitions changed.
    var metricsVersion = 0
    /// Key of the primary measure of the last analysis.
    var primaryKey = ""
    /// Series of the last analysis (time bins), for the group comparison's time course (RodentFlow 2.1).
    var metricSeries: [FlowResultSeries] = []
    /// Quality warnings of the last analysis (English).
    var qcFlags: [String] = []
    /// Left out of group comparisons (the session itself is kept), with the reason.
    var excluded = false
    var exclusionReason = ""
    /// Task id from a newer RodentFlow that this build does not know (the session is kept and written back
    /// with this id; it is not analysed here).
    var unknownParadigm: String?

    init() {}

    init(paradigm: Paradigm) {
        self.paradigm = paradigm
        self.params = AnalysisParams.defaults(for: paradigm)
        self.phase = paradigm.phases.first?.key ?? ""
        self.inference.animalCount = paradigm.animalCount
        self.calibration.kind = paradigm.defaultArena
    }

    var displaySubject: String { subjectID.isEmpty ? L10n.tr("未命名") : subjectID }
    var phaseTitle: String { paradigm.phaseTitle(phase) }

    /// "D2 · T3"-style label for day and trial.
    var sessionLabel: String {
        var parts: [String] = []
        if !phase.isEmpty { parts.append(phaseTitle) }
        if let day { parts.append("D\(day)") }
        if let trial { parts.append("T\(trial)") }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, paradigm, subjectID, group, sex, phase, day, trial, notes
        case videoName, videoFile, video, calibration, calibrationTime, params, inference, usedInference, usedModel, status, pose
        case metrics, metricOrder, metricLabels, primaryTitle, primaryDisplay
        case metricEntries, primaryKey, qcFlags, excluded, exclusionReason
        case metricSeries, metricsVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        createdAt = c.v(.createdAt, Date())
        updatedAt = c.v(.updatedAt, createdAt)
        paradigm = c.v(.paradigm, .poseOnly)
        if let raw = try? c.decode(String.self, forKey: .paradigm), Paradigm(rawValue: raw) == nil, !raw.isEmpty {
            unknownParadigm = raw
        }
        subjectID = c.v(.subjectID, "")
        group = c.v(.group, "")
        sex = c.v(.sex, "")
        phase = c.v(.phase, "")
        day = c.v(.day, nil as Int?)
        trial = c.v(.trial, nil as Int?)
        notes = c.v(.notes, "")
        videoName = c.v(.videoName, "")
        videoFile = c.v(.videoFile, nil as String?)
        video = c.v(.video, VideoMeta())
        calibration = c.v(.calibration, ArenaCalibration())
        calibrationTime = c.v(.calibrationTime, 0)
        params = c.v(.params, AnalysisParams.defaults(for: paradigm))
        inference = c.v(.inference, InferenceSettings())
        usedInference = c.v(.usedInference, nil as InferenceSettings?)
        usedModel = c.v(.usedModel, nil as String?)
        status = c.v(.status, .draft)
        pose = c.v(.pose, nil as PoseSummary?)
        metrics = c.v(.metrics, [:])
        metricOrder = c.v(.metricOrder, [])
        metricLabels = c.v(.metricLabels, [:])
        primaryTitle = c.v(.primaryTitle, "")
        primaryDisplay = c.v(.primaryDisplay, "")
        metricEntries = c.v(.metricEntries, [])
        primaryKey = c.v(.primaryKey, "")
        metricSeries = c.v(.metricSeries, [])
        metricsVersion = c.v(.metricsVersion, 0)
        qcFlags = c.v(.qcFlags, [])
        excluded = c.v(.excluded, false)
        exclusionReason = c.v(.exclusionReason, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(unknownParadigm ?? paradigm.rawValue, forKey: .paradigm)
        try c.encode(subjectID, forKey: .subjectID)
        try c.encode(group, forKey: .group)
        try c.encode(sex, forKey: .sex)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(day, forKey: .day)
        try c.encodeIfPresent(trial, forKey: .trial)
        try c.encode(notes, forKey: .notes)
        try c.encode(videoName, forKey: .videoName)
        try c.encodeIfPresent(videoFile, forKey: .videoFile)
        try c.encode(video, forKey: .video)
        try c.encode(calibration, forKey: .calibration)
        try c.encode(calibrationTime, forKey: .calibrationTime)
        try c.encode(params, forKey: .params)
        try c.encode(inference, forKey: .inference)
        try c.encodeIfPresent(usedInference, forKey: .usedInference)
        try c.encodeIfPresent(usedModel, forKey: .usedModel)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(pose, forKey: .pose)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(metricOrder, forKey: .metricOrder)
        try c.encode(metricLabels, forKey: .metricLabels)
        try c.encode(primaryTitle, forKey: .primaryTitle)
        try c.encode(primaryDisplay, forKey: .primaryDisplay)
        try c.encode(metricEntries, forKey: .metricEntries)
        try c.encode(primaryKey, forKey: .primaryKey)
        try c.encode(metricSeries, forKey: .metricSeries)
        try c.encode(metricsVersion, forKey: .metricsVersion)
        try c.encode(qcFlags, forKey: .qcFlags)
        try c.encode(excluded, forKey: .excluded)
        try c.encode(exclusionReason, forKey: .exclusionReason)
    }

    /// The task of this session (pose method).
    var studyAssay: StudyAssay? { StudyAssay(paradigm: paradigm) }

    /// The session as the group comparison sees it (nil until it has been analysed).
    func metricSummary() -> SessionMetricSummary? {
        guard !metricEntries.isEmpty else { return nil }
        var s = SessionMetricSummary(cacheKey: PoseMetricEntries.analyzerVersion, analyzer: PoseMetricEntries.analyzerVersion,
                                     computedAt: updatedAt, videoID: id, runFolder: id.uuidString, phase: phase,
                                     primaryKey: primaryKey, metrics: metricEntries)
        s.qcFlags = qcFlags
        s.series = metricSeries
        s.windowStart = params.windowStart
        s.windowLength = params.windowLength
        s.trackedFraction = pose?.detectionRate
        s.model = usedModel ?? kModelName
        if metricsVersion >= Analyzer.requiredMetricsVersion(paradigm) { s.definitions = SessionMetricSummary.currentDefinitions }
        return s
    }
}
