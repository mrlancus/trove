import CoreLocation
import Foundation
import TroveCore

/// Where this device is, for the clipboard's copy and paste history (PROTOCOL.md §8): from the
/// device's location (never an IP address), asked for once, kept for five minutes, with the place's
/// name and town looked up by Apple. Nil when location is off or not allowed.
@MainActor
final class PlaceFinder: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceFinder()

    private let manager = CLLocationManager()
    private var last: (at: Date, place: ClipEvent.Place)?
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> ClipEvent.Place? {
        if let last, Date().timeIntervalSince(last.at) < 300 { return last.place }
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default: break
        }
        let location: CLLocation? = await withCheckedContinuation { c in
            waiting.append(c)
            if waiting.count == 1 { manager.requestLocation() }
            // Don't hold a copy up for long.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.finish(nil)
            }
        }
        guard let location else { return last?.place }
        var place = ClipEvent.Place(lat: location.coordinate.latitude, lon: location.coordinate.longitude, accuracy: location.horizontalAccuracy)
        if let mark = try? await geocoder.reverseGeocodeLocation(location).first {
            place.name = mark.areasOfInterest?.first ?? mark.name
            place.city = mark.locality
        }
        last = (Date(), place)
        return place
    }

    private func finish(_ location: CLLocation?) {
        let list = waiting
        waiting = []
        for c in list { c.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.finish(l) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
