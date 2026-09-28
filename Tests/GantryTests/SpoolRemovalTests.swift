import Foundation
import Testing
@testable import Gantry

/// Wyjęcie rolki ze slotu.
///
/// Do tej pory nic tego nie robiło: `clearSlot` miało w całym programie jednego wywołującego, i to
/// tylko na wypadek włożenia rolki z tagiem na miejsce ręcznie przypisanej. Rolka wyjęta z AMS
/// zostawała przypisana do slotu, w którym jej nie ma, więc w magazynie jej nie było widać i żadna
/// inna drukarka nie mogła jej dostać. Przy filamencie bez tagu zostawała tam na zawsze.
@MainActor @Suite struct SpoolRemovalTests {
    private func store() -> (PhysicalSpoolStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (PhysicalSpoolStore(spoolsURL: dir.appendingPathComponent("spools.json"),
                                   usageURL: dir.appendingPathComponent("usage.json")), dir)
    }

    private func group(filled: Bool) -> FilamentGroup {
        let slot = FilamentSlot(id: "ams-0-0", label: "A1",
                                material: filled ? "PETG" : nil,
                                colorHex: filled ? "FF0000FF" : nil,
                                remainingPercent: filled ? 80 : nil, isActive: false)
        return FilamentGroup(id: "ams-0", sourceType: .ams, displayName: "AMS A", declaredCapacity: 4,
                             humidityPercent: nil, temperatureCelsius: nil, isExternal: false, slots: [slot])
    }

    /// Rolka w slocie, odczytana ze sklepu **po** przypisaniu: kopia sprzed niego nosi jeszcze starą
    /// lokalizację i zapisana z powrotem cofnęłaby to przypisanie.
    private func loaded(_ store: PhysicalSpoolStore) -> PhysicalSpool {
        let created = store.createRolls(definitionID: UUID(), count: 1, weight: 1000)[0]
        store.assign(spoolID: created.id, to: SpoolLocation(printerSerial: "K", feeder: .ams, amsIndex: 0, slot: 0))
        return store.spool(id: created.id) ?? created
    }

    @Test func anEmptySlotSendsItsRollBackToStorage() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roll = loaded(store)
        let noticed = Date()
        #expect(store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)], now: noticed).isEmpty,
                "a slot that just went empty is not a removal yet")
        let later = noticed.addingTimeInterval(PhysicalSpoolStore.removalGrace + 1)
        let detached = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)], now: later)
        #expect(detached.map(\.spoolID) == [roll.id])
        #expect(store.spool(id: roll.id)?.location.isStorage == true)
        #expect(store.spool(id: roll.id)?.status == .stored)
    }

    /// AMS przy zmianie szpuli potrafi na moment zgłosić pusty slot. Odpięcie w środku wydruku
    /// odesłałoby rolkę do magazynu i policzyło zużycie na nic.
    @Test func aBlinkOfAnEmptySlotIsNotARemoval() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roll = loaded(store)
        let start = Date()
        _ = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)], now: start)
        _ = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: true)],
                                     now: start.addingTimeInterval(20))
        let detached = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)],
                                                now: start.addingTimeInterval(PhysicalSpoolStore.removalGrace + 1))
        #expect(detached.isEmpty, "the countdown must start again once the slot reports filament")
        #expect(store.spool(id: roll.id)?.location.isStorage == false)
    }

    /// Milczenie drukarki to nie jest pusty AMS.
    @Test func aPrinterThatSaidNothingHasNotEmptiedAnything() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roll = loaded(store)
        let detached = store.detachRemovedRolls(printerSerial: "K", groups: [],
                                                now: Date().addingTimeInterval(3600))
        #expect(detached.isEmpty)
        #expect(store.spool(id: roll.id)?.location.isStorage == false)
    }

    private func tagged(_ uid: String?) -> FilamentGroup {
        var slot = FilamentSlot(id: "ams-0-0", label: "A1", material: "PETG", colorHex: "FF0000FF",
                                remainingPercent: 80, isActive: false)
        slot.remainingWeightGrams = 800
        slot.spoolUID = uid
        return FilamentGroup(id: "ams-0", sourceType: .ams, displayName: "AMS HT", declaredCapacity: 1,
                             humidityPercent: nil, temperatureCelsius: nil, isExternal: false, slots: [slot])
    }

    /// Wybudzenie Maca nie jest włożeniem rolki.
    ///
    /// Po wybudzeniu albo po ponownym połączeniu pierwsza telemetria przychodzi bez poprzedniej, więc
    /// każdy slot wyglądał jak dopiero co napełniony. Rolka wracała do magazynu, parowanie po tagu
    /// natychmiast wkładało ją z powrotem, a użytkownik dostawał tę samą parę komunikatów przy każdym
    /// otwarciu klapy.
    @Test func wakingTheMacDoesNotLookLikeSomebodyChangingSpools() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var roll = loaded(store)
        roll.tagUID = "A1B2C3"
        store.update(roll)
        #expect(store.detachAssignmentsReplacedByNFC(printerSerial: "K", previous: [],
                                                     current: [tagged("A1B2C3")]).isEmpty,
                "no earlier reading means nothing is known, not that a spool was just inserted")
        #expect(store.spool(id: roll.id)?.location.isStorage == false)
    }

    /// Rolka, której tag zgadza się ze slotem, jest dokładnie tą rolką.
    @Test func aRollWhoseTagMatchesTheSlotIsNotSentAway() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var roll = loaded(store)
        roll.tagUID = "A1B2C3"
        store.update(roll)
        let detached = store.detachAssignmentsReplacedByNFC(
            printerSerial: "K", previous: [group(filled: true)], current: [tagged("A1B2C3")])
        #expect(detached.isEmpty)
        // Za to inny tag w tym samym slocie znaczy, że ktoś naprawdę wymienił szpulę.
        let swapped = store.detachAssignmentsReplacedByNFC(
            printerSerial: "K", previous: [group(filled: true)], current: [tagged("DEADBEEF")])
        #expect(swapped.map(\.spoolID) == [roll.id])
    }

    /// Odpięta rolka jest znowu do wzięcia, więc inna drukarka może ją dostać.
    @Test func aReturnedRollIsAvailableToAnotherPrinter() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roll = loaded(store)
        _ = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)], now: Date())
        _ = store.detachRemovedRolls(printerSerial: "K", groups: [group(filled: false)],
                                     now: Date().addingTimeInterval(PhysicalSpoolStore.removalGrace + 1))
        let elsewhere = SpoolLocation(printerSerial: "M", feeder: .ams, amsIndex: 0, slot: 2)
        store.assign(spoolID: roll.id, to: elsewhere)
        #expect(store.spool(at: elsewhere)?.id == roll.id)
    }
}
