/*
 * rodentflow.h — the C interface of RodentFlowABI.dll (the RodentFlow shared engine).
 *
 * Reference copy of the contract. The Windows app does not compile against this header; it calls
 * the same symbols through P/Invoke (src/RodentFlow.Engine/RodentFlowNative.cs). Keep the three in
 * step: this file, ABI.swift, RodentFlowNative.cs.
 *
 * Conventions
 *   - Every char* returned by this library is a UTF-8, NUL-terminated string that the caller owns
 *     until it passes it back to rf_string_free(). Do not free it any other way.
 *   - Requests and results are JSON. Results are either {"ok":true, ...} or {"ok":false,"error":"…"}.
 *   - Pixel coordinates are pixels of the upright whole video frame (origin top-left).
 *   - Not thread-safe per run: drive one run handle from one thread.
 */

#ifndef RODENTFLOW_H
#define RODENTFLOW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status codes returned by rf_run_filter / rf_run_frame ---- */
#define RF_ANALYZE             1   /* rf_run_filter: run the model on this frame        */
#define RF_SKIP                0   /* rf_run_filter: skip (stride) | rf_run_frame: ok   */
#define RF_BEFORE_RANGE       -1   /* before the analysed range: keep decoding          */
#define RF_PAST_RANGE         -2   /* past the analysed range: stop decoding            */
#define RF_BAD_HANDLE        -10
#define RF_BAD_ARGUMENT      -11
#define RF_WRITE_FAILED      -12
#define RF_TOO_MANY_FAILURES -13   /* rows written so far are kept; analyse again        */

/* ---- library ---- */

/* {"app","version","build","abi","keypoints":[…],"models":[…]} */
char *rf_version(void);

/* Releases a string returned by this library. */
void rf_string_free(char *s);

/* 0 = English, 1 = Chinese. Set before analysing. */
void rf_set_language(int32_t chinese);

/* The task catalogue, keypoint names and model names, for the host's task list. Each task carries
 * what its setup needs: arenaKinds, defaultArena, markers, phases, defaultArenaSize, companions,
 * primaryMetric, tagline, summary, setupTips. "arenaKinds" lists every shape with its maze labels. */
char *rf_catalogue(void);

/* ---- setup (ABI/Setup.swift) ----
 *
 * rf_plan_run      { settings, calibration, frameWidth, frameHeight }
 *                  → modelName, animalCount, roi, crop, decodeScale …
 * rf_default_setup { paradigm, arena?, frameWidth, frameHeight, params? }
 *                  → calibration, params   (params given = reset of the handles only)
 * rf_setup_view    { session, frameWidth, frameHeight }
 *                  → zones[], handles[], region, isMetric, pixelsPerCM, calibration, params
 * rf_move_handle   { session, frameWidth, frameHeight, handle, x, y }
 *                  → the same as rf_setup_view, for the setup after the move
 *
 * Points are normalized to the upright frame (0–1, origin top-left). The calibration and params
 * returned are the setup as the engine reads it; keep those rather than what was sent. */
char *rf_plan_run(const char *request_json);
char *rf_default_setup(const char *request_json);
char *rf_setup_view(const char *request_json);
char *rf_move_handle(const char *request_json);

/* ---- tracking run ----
 *
 * request JSON:
 *   { "videoName": "cage3.mp4", "destination": "C:\\…\\run",
 *     "modelName": "MousePose6_960_int8",
 *     "settings": { …InferenceSettings… },      // stride, grayscale, animalCount, startTime,
 *                                               // endTime, region, arenaMargin, coat
 *     "roi": {"x":0,"y":0,"w":1,"h":1} | null,  // region given to the model, normalized
 *     "fps": 29.97, "frameWidth": 1920, "frameHeight": 1080, "videoDuration": 600.0,
 *     "sourceSize": 123456789, "sourceModification": 1762000000.0,
 *     "sourceFingerprint": "…", "decodeScale": null,
 *     "modelInputWidth": 960, "modelInputHeight": 960 }
 *
 * result JSON adds "handle" plus animalCount, appearanceDims, confidenceThreshold, maxDetections,
 * stride, rangeStart, rangeEnd, resumeAfter, decodeScale, roi, grayscale, totalSegments.
 */
char *rf_run_open(const char *request_json);

/* Call for every decoded frame, in presentation order, before running the model.
 * Returns RF_ANALYZE (frame_number_out is set), RF_SKIP, RF_BEFORE_RANGE or RF_PAST_RANGE. */
int32_t rf_run_filter(int32_t handle, double time, int32_t *frame_number_out);

/* One analysed frame.
 *   tensor            the model's end-to-end output as float32, or NULL if the model failed on
 *                     this frame (the row is written as "no animal")
 *   detections/fields the output shape, e.g. 300 and 24 for [1,300,24]
 *   *_stride          element strides of those two axes, e.g. 24 and 1
 *   crop_*            the region given to the model, in upright whole-frame pixels
 *   bgra              the decoded upright frame, 32-bit BGRA, for fur colour with two animals;
 *                     NULL for one animal or a group
 *   poses_json_out    optional; receives the poses written, or the error message
 * Returns 0, or a negative status. */
int32_t rf_run_frame(int32_t handle,
                     int32_t frame_number, double time,
                     const float *tensor, int32_t tensor_count,
                     int32_t detections, int32_t fields,
                     int32_t detection_stride, int32_t field_stride,
                     double crop_x, double crop_y, double crop_w, double crop_h,
                     const uint8_t *bgra, int32_t bgra_width, int32_t bgra_height,
                     int32_t bgra_row_bytes,
                     char **poses_json_out);

/* {"completedSegments","totalSegments","currentSegment","processedInSegment","sourceTime",
 *  "sourceDuration","analysedFrames"} */
char *rf_run_progress(int32_t handle);

/* Writes pose.mpt (A/B resolved over the whole video for two animals).
 * ms_per_frame is the host's measured model time, recorded in the track. */
char *rf_run_finish(int32_t handle, double ms_per_frame);

/* Stops and forgets the run. Rows already written are kept; the folder can be continued. */
void rf_run_close(int32_t handle);

/* ---- analysis ----
 *
 * request JSON:
 *   { "session": { …Session… }, "poseFile": "C:\\…\\pose.mpt", "outDir": "C:\\…\\results",
 *     "companion": {"key": 1.0} | null, "marbles": {…} | null, "writeExports": true,
 *     "includeReport": true, "reportLanguage": "interface" | "english" }
 *
 * result JSON: outDir, written[], paradigm, task, model, animalCount, frames, fps, windowStart,
 *              metrics[{key,title,unit,value,decimals,highlight,censored?,valueText?}],
 *              warnings[], notes[],
 *              report (with includeReport; ABI/ReportView.swift): language, category, primaryKey,
 *                keyNote?, metrics[] (with display, scale), warnings[], methods[], methodsText,
 *                quality, blocks[] (kind arena | timeline | bars | line | polar | table, csv?,
 *                styleKey), layerTitles, backdropTitles, review
 */
char *rf_analyze(const char *request_json);

/* Interface texts through the engine's catalogue (L10n.tr), so the host's result page uses the same
 * words as the Mac's: { "texts": ["全部指标", "%d 条提示"], "english": false } → { "ok": true,
 * "texts": ["All measures", "%d notes"] }. With "english": true, English whatever the language. */
char *rf_translate(const char *request_json);

/* ---- frame review (ABI/ReviewABI.swift) ----
 *
 * The report (rf_analyze with includeReport) carries review.qc: runs of frames to check (noDetection,
 * animalMissing, lowConfidence < 0.35, outsideArena, identitySuspect, identityUncertain, overlapping), each
 * {kind, title, firstIndex, lastIndex, frames, start, end}.
 *
 * rf_swap_identity  { "poseFile": "…", "at": 1234 }  or  { "poseFile": "…", "from": 100, "to": 400 }
 *                   → { ok, swapped, changed: [first, last] | null }. Rewrites pose.mpt (two animals only);
 *                   analyse again (rf_analyze) for the corrected results.
 * rf_identity_segments  pose.mpt → { ok, segments: [[first, last], …] } (track indices). */
char *rf_swap_identity(const char *request_json);
char *rf_identity_segments(const char *pose_file);

/* ---- marble burying (ABI/MarbleABI.swift) ----
 *
 * rf_marble_plan  Session JSON → { ok, needed, key, centers: [[x, y], …] (upright pixels), radius, interval,
 *                 frameWidth, frameHeight }. The host reads each marble's luminance (inside 0.8 × radius) and the
 *                 bedding ring's (1.3–2 × radius) every interval seconds and sends them as rf_analyze's "marbles"
 *                 ({key, times, inner, ring}; a non-finite reading as "nan", as the Mac's marble_samples.json). */
char *rf_marble_plan(const char *session_json);

/* ---- group comparison (ABI/GroupABI.swift) ----
 *
 * rf_analyze with includeReport also returns "summary": the session's SessionMetricSummary (as the Mac saves one per
 * session). The host keeps it unchanged with the session.
 *
 * rf_group_analysis  { paradigm, taskName, sessions: [{id, subjectID, subjectKey, group, phase, day?, trial?, session?,
 *                      date?, excluded, exclusionReason?, sex?, trackingProblem?, summary}], request?, style?, english? }
 *                    → { ok, request, style, options, result {summary, details, descriptives, statsCsv, longCsv, …},
 *                        figure {width, height, background, items}, svg }
 *                    GroupAnalysisEngine.run + PubGroupFigure.build: the figure the Mac shows and exports. */
char *rf_group_analysis(const char *request_json);

/* ---- reading a finished track ---- */

char *rf_track_info(const char *pose_file);
char *rf_track_frames(const char *pose_file, int32_t from, int32_t count);

#ifdef __cplusplus
}
#endif

#endif /* RODENTFLOW_H */
