import Testing
import Foundation
@testable import Gantry

/// Who is allowed to take the camera.
///
/// A printer camera accepts one client at a time. A second connection does not get a second copy of
/// the picture, it takes the first one away. So everything that wants a frame on a timer, the defect
/// watcher and the remote page, has to ask whether a preview is already running before opening a
/// connection of its own. That is not hypothetical: the moment the defect watcher had something to
/// compare against and actually started running, it took the camera off the edge panel every few
/// seconds and left "No picture" over a preview that was working.
///
/// The registry is driven here directly rather than through `start()`, which would open a real
/// stream to a real printer.
@MainActor @Suite(.serialized) struct CameraSharingTests {
    private func feed(_ serial: String) -> CameraFeedController {
        CameraFeedController(store: PrinterStore(), serial: serial)
    }

    @Test func nobodyWatchingMeansTheCameraIsFree() {
        #expect(CameraFeedController.isLive(serial: "TEST-FREE") == false)
        #expect(CameraFeedController.liveFrameJPEG(serial: "TEST-FREE") == nil)
    }

    @Test func aPreviewClaimsItsPrinterAndGivesItBack() {
        let preview = feed("TEST-CLAIM")
        preview.startedWatching()
        #expect(CameraFeedController.isLive(serial: "TEST-CLAIM"), "a running preview must be visible to the watcher")
        #expect(CameraFeedController.isLive(serial: "TEST-OTHER") == false, "only its own printer")
        preview.stoppedWatching()
        #expect(CameraFeedController.isLive(serial: "TEST-CLAIM") == false, "the camera was never given back")
    }

    @Test func twoSurfacesOnOnePrinterBothHaveToLetGo() {
        // The edge panel and Details can show the same printer at once, and the camera is only free
        // again when the last of them has gone.
        let panel = feed("TEST-TWO")
        let details = feed("TEST-TWO")
        panel.startedWatching()
        details.startedWatching()
        panel.stoppedWatching()
        #expect(CameraFeedController.isLive(serial: "TEST-TWO"), "one surface closing is not all of them")
        details.stoppedWatching()
        #expect(CameraFeedController.isLive(serial: "TEST-TWO") == false)
    }

    @Test func aSurfaceTornDownWithoutStoppingDoesNotHoldTheCameraForEver() {
        do {
            let gone = feed("TEST-GONE")
            gone.startedWatching()
            #expect(CameraFeedController.isLive(serial: "TEST-GONE"))
        }
        // Otherwise the watcher would decide this printer is busy and never look at it again.
        #expect(CameraFeedController.isLive(serial: "TEST-GONE") == false)
    }

    @Test func aPreviewWithNoFrameToGiveHandsOverNothingRatherThanAWrongFrame() {
        let preview = feed("TEST-H264")
        preview.startedWatching()
        defer { preview.stoppedWatching() }
        // Bambu's RTSP preview is H.264 and the display layer keeps no pixels, so there is no frame
        // to pass on even while the picture is plainly on screen. The answer is nothing, and the
        // caller waits: the one thing it must not do is go and open its own connection.
        #expect(CameraFeedController.liveFrameJPEG(serial: "TEST-H264") == nil)
        #expect(CameraFeedController.isLive(serial: "TEST-H264"), "still busy, even with no frame to give")
    }
}
