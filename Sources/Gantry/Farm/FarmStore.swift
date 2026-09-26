import Foundation
import Combine

@MainActor protocol FarmTransport {
    func upload(printer: SavedPrinter, file: URL, remoteName: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func send(serial: String, json: String) throws
}
@MainActor private struct LiveFarmTransport: FarmTransport {
    let printers: PrinterStore
    func upload(printer: SavedPrinter, file: URL, remoteName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let code = printers.accessCode(for: printer.serial), !code.isEmpty else { throw FarmError(message: "Brak kodu dostępu do drukarki.") }
        try await BambuFileClient(host: printer.host, accessCode: code).upload(file: file, remoteName: remoteName, progress: progress)
    }
    func send(serial: String, json: String) throws { try printers.sendFarmCommand(serial: serial, json: json) }
}

@MainActor final class FarmStore: ObservableObject {
    struct Snapshot: Codable { var files:[FarmFile]; var jobs:[FarmJob]; var queue:[FarmQueueItem]? = nil }
    let printers: PrinterStore
    let root: URL
    @Published private(set) var files:[FarmFile]=[]
    @Published private(set) var jobs:[FarmJob]=[]
    @Published private(set) var progress:[UUID:Double]=[:]
    @Published private(set) var queue:[FarmQueueItem]=[]
    /// Printers whose bed the user confirmed empty. Kept in memory only: after a restart nobody vouches
    /// for the bed any more. Consumed by the one start it allows.
    @Published private(set) var armed:Set<String>=[]
    @Published var notice=""
    private var tasks:[UUID:Task<Void,Never>]=[:]
    private var subscription:AnyCancellable?
    private var timer:Timer?
    private var storageReady=true
    private let transport: any FarmTransport
    private let holdsPower: Bool

    init(printers:PrinterStore,root:URL?=nil,transport:(any FarmTransport)?=nil,holdsPower:Bool=true) {
        self.transport=transport ?? LiveFarmTransport(printers:printers)
        self.holdsPower=holdsPower
        self.printers=printers
        self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Gantry/Farm",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true)
            let index=self.root.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath:index.path) {
                let s=try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:index));files=s.files;jobs=s.jobs;queue=s.queue ?? []
                for i in jobs.indices {
                    if jobs[i].state == .uploading { jobs[i].state = .failed;jobs[i].message="Transfer przerwany przez zamknięcie aplikacji. Wyślij ponownie." }
                    if jobs[i].state == .awaitingStart { jobs[i].state = .uncertain;jobs[i].message="Start wysłano przed restartem. Sprawdź drukarkę; polecenie nie zostanie powtórzone." }
                }
                try persist()
            }
        } catch { storageReady=false;notice="Nie można odczytać biblioteki: \(error.localizedDescription)" }
        subscription=printers.$telemetry.sink { [weak self] values in
            Task { @MainActor [weak self] in self?.reconcile(values) }
        }
        timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self else{return};self.reconcile(self.printers.telemetry) }
        }
    }
    func fileURL(_ id:UUID)->URL { root.appendingPathComponent(id.uuidString+".3mf") }
    func persist() throws {
        guard storageReady else { throw FarmError(message:"Biblioteka jest niedostępna. Nie można bezpiecznie zapisać zadania.") }
        try JSONEncoder().encode(Snapshot(files:files,jobs:jobs,queue:queue)).write(to:root.appendingPathComponent("index.json"),options:.atomic)
    }
    func importFile(_ url:URL) async {
        do {
            guard storageReady else { throw FarmError(message:"Biblioteka jest niedostępna.") }
            let id=UUID(), dest=fileURL(id)
            let file=try await Task.detached(priority:.userInitiated) {
                let resource=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                guard resource.isRegularFile==true,let size=resource.fileSize,size<=512*1024*1024 else { throw FarmError(message:"Wybierz plik 3MF do 512 MB.") }
                let data=try Data(contentsOf:url,options:.mappedIfSafe)
                let archive=try FarmArchive(data:data),plates=try archive.plates()
                try data.write(to:dest,options:.atomic)
                for plate in plates {
                    if let preview=archive.preview(plate.index) { try preview.write(to:dest.deletingPathExtension().appendingPathExtension("plate-\(plate.index).png"),options:.atomic) }
                }
                return FarmFile(id:id,name:url.lastPathComponent,bytes:data.count,plates:plates,importedAt:Date())
            }.value
            files.append(file)
            do { try persist() } catch { files.removeAll{$0.id==id};throw error }
            notice="Dodano \(file.name) · \(file.plates.count) płyt."
        } catch { notice=error.localizedDescription }
    }
    func previewURL(_ id:UUID,plate:Int)->URL { fileURL(id).deletingPathExtension().appendingPathExtension("plate-\(plate).png") }
    func upload(file:FarmFile,plate:FarmPlate,printer:SavedPrinter,mapping:[Int],queueItemID:UUID?=nil,autoStart:Bool=false) throws {
        guard printer.kind == .bambu else { throw FarmError(message:"Wysyłanie obsługuje obecnie drukarki Bambu Lab.") }
        guard !jobs.contains(where:{$0.serial==printer.serial && $0.state == .uploading}) else { throw FarmError(message:"Ta drukarka już odbiera plik.") }
        let id=UUID(),date=Date()
        let job=FarmJob(id:id,fileID:file.id,fileName:file.name,serial:printer.serial,printerName:printer.name,plate:plate,mapping:mapping,remoteName:"gantry-\(id.uuidString).3mf",state:.uploading,message:"Wysyłanie…",createdAt:date,updatedAt:date,queueItemID:queueItemID,autoStart:autoStart ? true:nil)
        jobs.insert(job,at:0)
        do {try persist()} catch {jobs.removeAll{$0.id==id};throw error}
        let hold=holdsPower ? KeepAwake.shared.beginOperation() : nil,url=fileURL(file.id)
        let transport=self.transport
        tasks[id]=Task { [weak self] in
            defer { if let hold { KeepAwake.shared.endOperation(hold) };self?.tasks.removeValue(forKey:id);self?.progress.removeValue(forKey:id) }
            do {
                try await transport.upload(printer:printer,file:url,remoteName:job.remoteName) { [weak self] value in
                    Task { @MainActor [weak self] in self?.progress[id]=value }
                }
                self?.update(id,state:.uploaded,message:"Plik na drukarce. Druk nie został uruchomiony.")
            } catch {
                self?.update(id,state:.failed,message:Task.isCancelled ? "Anulowano transfer. Nie uruchomiono druku." : error.localizedDescription)
                self?.returnToQueue(job)
            }
        }
    }
    func cancel(_ id:UUID) { tasks[id]?.cancel() }

    // MARK: Queue
    func enqueue(file:FarmFile,plate:FarmPlate,copies:Int,printers serials:[String]) throws {
        guard (1...99).contains(copies) else { throw FarmError(message:"Liczba kopii: od 1 do 99.") }
        guard !plate.filaments.isEmpty else { throw FarmError(message:"Brak informacji o filamentach w pliku. Kolejka dobiera AMS po materiale i kolorze.") }
        let item=FarmQueueItem(id:UUID(),fileID:file.id,fileName:file.name,plate:plate,copies:copies,printers:serials,createdAt:Date())
        queue.append(item)
        do { try persist() } catch { queue.removeAll{$0.id==item.id};throw error }
        notice="Do kolejki: \(file.name) · płyta \(plate.index) × \(copies)."
        reconcile(printers.telemetry)
    }
    func removeFromQueue(_ id:UUID) {
        let previous=queue;queue.removeAll{$0.id==id}
        do { try persist() } catch { queue=previous;notice=error.localizedDescription }
    }
    func moveUp(_ id:UUID) {
        guard let i=queue.firstIndex(where:{$0.id==id}),i>0 else { return }
        let previous=queue;queue.swapAt(i,i-1)
        do { try persist() } catch { queue=previous;notice=error.localizedDescription }
    }
    /// The user confirms this printer's bed is empty: the queue may send and start one job on it.
    func arm(_ serial:String) throws {
        guard printers.printers.contains(where:{$0.serial==serial && $0.kind == .bambu}) else { throw FarmError(message:"Kolejka obsługuje drukarki Bambu Lab.") }
        if let state=printers.telemetry[serial]?.state,state == .printing || state == .paused { throw FarmError(message:"Drukarka drukuje. Oznacz stół jako pusty po zdjęciu wydruku.") }
        armed.insert(serial)
        reconcile(printers.telemetry)
    }
    func disarm(_ serial:String) { armed.remove(serial) }
    private func returnToQueue(_ job:FarmJob) {
        guard let itemID=job.queueItemID else { return }
        // The bed confirmation belonged to this attempt; without it the copy would go straight back out.
        armed.remove(job.serial)
        if let i=queue.firstIndex(where:{$0.id==itemID}) { queue[i].copies+=1 }
        else { queue.insert(FarmQueueItem(id:itemID,fileID:job.fileID,fileName:job.fileName,plate:job.plate,copies:1,printers:[],createdAt:job.createdAt),at:0) }
        do { try persist() } catch { notice=error.localizedDescription }
    }
    private func activeJob(on serial:String)->Bool {
        jobs.contains { $0.serial==serial && [.uploading,.uploaded,.awaitingStart,.uncertain,.printing].contains($0.state) }
    }
    private func dispatchQueue(_ telemetry:[String:PrinterTelemetry]) {
        guard storageReady,!queue.isEmpty else { return }
        for serial in armed.sorted() {
            guard let printer=printers.printers.first(where:{$0.serial==serial && $0.kind == .bambu}) else { armed.remove(serial);continue }
            guard !activeJob(on:serial),let t=telemetry[serial],FarmRules.startBlock(t)==nil,!printers.requiresSignedCommands(serial:serial) else { continue }
            guard let next=FarmRules.nextQueueItem(queue,serial:serial,telemetry:t) else { continue }
            let item=queue[next.index]
            guard let file=files.first(where:{$0.id==item.fileID}) else {
                queue.remove(at:next.index);notice="Usunięto z kolejki \(item.fileName): brak pliku w bibliotece.";try? persist();continue
            }
            do { try upload(file:file,plate:item.plate,printer:printer,mapping:next.mapping,queueItemID:item.id,autoStart:true) }
            catch { notice="\(printer.name): \(error.localizedDescription)";continue }
            if queue[next.index].copies>1 { queue[next.index].copies-=1 } else { queue.remove(at:next.index) }
            do { try persist() } catch { storageReady=false;notice="Nie udało się zapisać kolejki. Wysyłki są zablokowane: \(error.localizedDescription)";return }
        }
    }
    private func startArmedUploads() {
        for job in jobs where job.state == .uploaded && job.autoStart == true && armed.contains(job.serial) {
            if let reason=blockReason(job) {
                let message="Automatyczny start wstrzymany: \(reason)"
                if job.message != message { update(job.id,state:.uploaded,message:message) }
                continue
            }
            armed.remove(job.serial)
            do { try start(job.id,bedConfirmed:true,profileConfirmed:true) }
            catch { notice="\(job.printerName): \(error.localizedDescription)" }
        }
    }
    func blockReason(_ job:FarmJob)->String? {
        guard job.state == .uploaded else { return "To zadanie nie oczekuje na uruchomienie." }
        guard printers.printers.contains(where:{$0.serial==job.serial}) else{return "Drukarka została usunięta."}
        if jobs.contains(where:{$0.serial==job.serial && [.awaitingStart,.uncertain,.printing].contains($0.state)}) {return "Poprzednie zadanie tej drukarki wymaga zakończenia lub sprawdzenia."}
        if printers.requiresSignedCommands(serial:job.serial) { return "Drukarka wymaga podpisanych poleceń. Sprawdź tryb LAN / Developer Mode." }
        if let reason=FarmRules.startBlock(printers.telemetry[job.serial]) {return reason}
        guard !job.plate.filaments.isEmpty else { return "Brak informacji o filamentach w pliku. Wyeksportuj płytę z Bambu Studio." }
        if job.mapping.isEmpty {
            guard job.plate.filaments.count==1 else {return "Wydruk wielomateriałowy wymaga przypisania AMS."}
        } else {
            let slots=printers.telemetry[job.serial]?.amsSlots ?? []
            for f in job.plate.filaments {
                guard f.id <= job.mapping.count, let slot=slots.first(where:{FarmRules.slotIndex($0.id)==job.mapping[f.id-1]}), slot.material.caseInsensitiveCompare(f.material) == .orderedSame else {return "Przypisanie AMS jest niekompletne lub materiał w slocie się zmienił."}
            }
        }
        if let requested=job.plate.nozzle,let actual=printers.telemetry[job.serial]?.nozzleDiameter,abs(requested-actual)>0.01 {return "Średnica dyszy różni się od profilu pliku."}
        return nil
    }
    /// Called only after the panel's explicit confirmation; persistence precedes the irreversible send.
    func start(_ id:UUID,bedConfirmed:Bool,profileConfirmed:Bool) throws {
        guard bedConfirmed,profileConfirmed,let i=jobs.firstIndex(where:{$0.id==id}) else {throw FarmError(message:"Potwierdź pusty stół i profil drukarki.")}
        if let reason=blockReason(jobs[i]) {throw FarmError(message:reason)}
        let previous=jobs[i]
        jobs[i].state = .awaitingStart;jobs[i].startRequestedAt=Date();jobs[i].updatedAt=Date();jobs[i].message="Wysłano start. Oczekiwanie na potwierdzenie drukarki…"
        do {try persist()} catch {jobs[i]=previous;throw error}
        do {try transport.send(serial:jobs[i].serial,json:FarmRules.command(jobs[i]))}
        catch {update(id,state:.uncertain,message:"Nie potwierdzono wysłania startu. Sprawdź drukarkę.");throw error}
    }
    func resolve(_ id:UUID) {
        guard let i=jobs.firstIndex(where:{$0.id==id}),jobs[i].state == .uncertain else{return}
        update(id,state:.failed,message:"Użytkownik sprawdził drukarkę i zamknął niepotwierdzone zadanie. Nie ponowiono startu.")
    }
    private func update(_ id:UUID,state:FarmJob.State,message:String) {
        guard let i=jobs.firstIndex(where:{$0.id==id}) else{return}
        jobs[i].state=state;jobs[i].message=message;jobs[i].updatedAt=Date()
        do {try persist()} catch {storageReady=false;notice="Nie udało się zapisać stanu. Nowe wysyłki i starty są zablokowane: \(error.localizedDescription)"}
    }
    func reconcile(_ telemetry:[String:PrinterTelemetry]) {
        for job in jobs where [.awaitingStart,.uncertain,.printing].contains(job.state) {
            if let t=telemetry[job.serial],let date=t.lastUpdated,date >= (job.startRequestedAt ?? job.createdAt),Date().timeIntervalSince(date)<30,FarmRules.matches(job,t) {
                if t.state == .printing || t.state == .paused {
                    if job.state != .printing {update(job.id,state:.printing,message:"Drukarka potwierdziła ten wydruk.")}
                } else if t.state == .finished {update(job.id,state:.finished,message:"Wydruk zakończony. Odbierz elementy ze stołu.")}
                else if t.state == .error {update(job.id,state:.failed,message:"Drukarka zgłosiła błąd podczas wydruku.")}
            }
            if job.state == .printing, let t=telemetry[job.serial], let date=t.lastUpdated,
               Date().timeIntervalSince(date)<30, (t.state == .idle || (t.state == .printing && !FarmRules.matches(job,t))) {
                update(job.id,state:.uncertain,message:"Wydruk został przerwany lub drukarka wykonuje inne zadanie. Sprawdź jej stan.")
            }
            if job.state == .awaitingStart,Date().timeIntervalSince(job.startRequestedAt ?? Date())>60,jobs.first(where:{$0.id==job.id})?.state == .awaitingStart {
                update(job.id,state:.uncertain,message:"Brak potwierdzenia startu. Sprawdź drukarkę. Polecenie nie będzie automatycznie ponawiane.")
            }
        }
        startArmedUploads()
        dispatchQueue(telemetry)
    }
}
