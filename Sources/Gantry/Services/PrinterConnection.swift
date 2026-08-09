import Foundation

/// A live connection to one printer that emits status events. Implemented by MQTTClient (Bambu)
/// and MoonrakerClient (Klipper); both report through MQTTClient.Event so PrinterStore handles
/// them the same way.
protocol PrinterConnection: AnyObject {
    func start()
    func stop()
}
