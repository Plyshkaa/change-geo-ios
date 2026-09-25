import AppKit
import CoreLocation
import Foundation
import MapKit

private enum PointSelection {
    case start
    case end
}

private struct OSRMResponse: Decodable {
    let code: String
    let routes: [OSRMRoute]
}

private struct OSRMRoute: Decodable {
    let distance: Double
    let geometry: OSRMGeometry
}

private struct OSRMGeometry: Decodable {
    let coordinates: [[Double]]
}

private struct OSMSearchResult: Decodable {
    let latitude: String
    let longitude: String
    let displayName: String
    let boundingBox: [String]?

    private enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case displayName = "display_name"
        case boundingBox = "boundingbox"
    }
}

private final class ClickableMapView: MKMapView {
    var onMapClick: ((CLLocationCoordinate2D) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMapClick?(convert(point, toCoordinateFrom: self))
        super.mouseDown(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MKMapViewDelegate, NSTextFieldDelegate, CLLocationManagerDelegate {
    private var window: NSWindow!
    private let mapView = ClickableMapView()
    private let locationManager = CLLocationManager()
    private var session: Process?
    private var temporaryGPXURL: URL?
    private var directions: MKDirections?
    private var routeTask: URLSessionDataTask?
    private var osmRouteWorkItem: DispatchWorkItem?
    private var lastOSMRequestDate: Date?
    private var localSearch: MKLocalSearch?
    private var searchTask: URLSessionDataTask?
    private var searchWorkItem: DispatchWorkItem?
    private var lastOSMSearchDate: Date?
    private var searchGeneration = 0
    private lazy var routingSession = URLSession(configuration: .ephemeral)
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var routeDistance = 0.0
    private var routeGeneration = 0
    private var routeUsesOpenStreetMap = false
    private var searchUsesOpenStreetMap = false
    private var isWaitingForMacLocation = false
    private var locationRequestID = 0
    private var movementTimer: Timer?
    private var movementStartDate: Date?
    private var movementCoordinates: [CLLocationCoordinate2D] = []
    private var movementCumulativeDistances: [CLLocationDistance] = []
    private var movementTotalDistance: CLLocationDistance = 0
    private var movementSpeedMetersPerSecond = 0.0
    private var movementReturnsToStart = false

    private let modeControl = NSSegmentedControl(labels: ["Точка", "Маршрут"], trackingMode: .selectOne, target: nil, action: nil)
    private let selectionControl = NSSegmentedControl(labels: ["Начало", "Конец"], trackingMode: .selectOne, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 36, minValue: 1, maxValue: 120, target: nil, action: nil)
    private let directionControl = NSSegmentedControl(labels: ["В одну сторону", "Туда и обратно"], trackingMode: .selectOne, target: nil, action: nil)
    private let latitudeField = NSTextField(string: "")
    private let longitudeField = NSTextField(string: "")
    private let searchField = NSSearchField()
    private let devicePicker = NSPopUpButton()
    private var deviceIDs: [String] = []

    private let currentValue = NSTextField(labelWithString: "Выберите точку на карте")
    private let destinationValue = NSTextField(labelWithString: "Выберите точку на карте")
    private let speedValue = NSTextField(labelWithString: "36 км/ч")
    private let distanceValue = NSTextField(labelWithString: "Расстояние: -")
    private let statusLabel = NSTextField(labelWithString: "Подключите iPhone по USB")
    private let actionButton = NSButton(title: "Установить геопозицию", target: nil, action: nil)
    private let routeControls = NSView()
    private let pointControls = NSView()
    private let osmAttributionButton = NSButton(title: "© OpenStreetMap contributors", target: nil, action: nil)

    private var selection: PointSelection = .end
    private var startCoordinate: CLLocationCoordinate2D?
    private var endCoordinate: CLLocationCoordinate2D?
    private var routeOverlay: MKPolyline?
    private var routeOutlineOverlay: MKPolyline?
    private var startAnnotation: MKPointAnnotation?
    private var endAnnotation: MKPointAnnotation?
    private var macLocationAnnotation: MKPointAnnotation?
    private var movementAnnotation: MKPointAnnotation?
    private var searchAnnotation: MKPointAnnotation?

    private var projectRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["LOCATION_CONTROLLER_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private var pythonURL: URL {
        projectRoot.appendingPathComponent(".venv/bin/python")
    }

    private var controllerURL: URL {
        projectRoot.appendingPathComponent("locationctl.py")
    }

    private var bundledBackendURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("backend/locationctl"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private var backendURL: URL { bundledBackendURL ?? pythonURL }

    private func backendArguments(_ arguments: [String]) -> [String] {
        bundledBackendURL == nil ? [controllerURL.path] + arguments : arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanupStaleTemporaryGPX()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = kCLDistanceFilterNone
        let content = makeContentView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iOS Location Controller"
        window.minSize = NSSize(width: 860, height: 560)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        listDevices()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        osmRouteWorkItem?.cancel()
        localSearch?.cancel()
        searchTask?.cancel()
        searchWorkItem?.cancel()
        routingSession.invalidateAndCancel()
        stopSession()
        return .terminateNow
    }

    private func makeContentView() -> NSView {
        configureControls()

        let sidebar = makeSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.onMapClick = { [weak self] coordinate in
            self?.select(coordinate: coordinate)
        }
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.mapType = .standard
        mapView.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        ), animated: false)

        let root = NSView()
        root.addSubview(mapView)
        root.addSubview(sidebar)

        let searchPanel = NSBox()
        searchPanel.boxType = .custom
        searchPanel.fillColor = .windowBackgroundColor
        searchPanel.borderColor = .separatorColor
        searchPanel.borderWidth = 1
        searchPanel.cornerRadius = 10
        searchPanel.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchContent = NSView()
        searchContent.addSubview(searchField)
        searchPanel.contentView = searchContent
        root.addSubview(searchPanel)

        let locateButton = NSButton(image: NSImage(systemSymbolName: "location.north.fill", accessibilityDescription: "К моей позиции") ?? NSImage(), target: self, action: #selector(centerOnMyLocation))
        locateButton.bezelStyle = .regularSquare
        locateButton.toolTip = "К моей позиции (геопозиция Mac)"
        locateButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(locateButton)

        osmAttributionButton.target = self
        osmAttributionButton.action = #selector(openOSMCopyright)
        osmAttributionButton.bezelStyle = .inline
        osmAttributionButton.controlSize = .small
        osmAttributionButton.font = .systemFont(ofSize: 11)
        osmAttributionButton.toolTip = "Лицензия и авторы данных OpenStreetMap"
        osmAttributionButton.isHidden = true
        osmAttributionButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(osmAttributionButton)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 350),
            mapView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            mapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: root.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchPanel.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 16),
            searchPanel.topAnchor.constraint(equalTo: root.topAnchor, constant: 70),
            searchPanel.widthAnchor.constraint(equalToConstant: 360),
            searchPanel.heightAnchor.constraint(equalToConstant: 54),
            searchPanel.trailingAnchor.constraint(lessThanOrEqualTo: locateButton.leadingAnchor, constant: -12),
            searchField.leadingAnchor.constraint(equalTo: searchContent.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchContent.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchContent.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            locateButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            locateButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            locateButton.widthAnchor.constraint(equalToConstant: 38),
            locateButton.heightAnchor.constraint(equalToConstant: 38),
            osmAttributionButton.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 12),
            osmAttributionButton.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -28)
        ])
        return root
    }

    @objc private func openOSMCopyright() {
        guard let url = URL(string: "https://www.openstreetmap.org/copyright") else { return }
        NSWorkspace.shared.open(url)
    }

    private var hasMacLocationAuthorization: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    @objc private func centerOnMyLocation() {
        guard CLLocationManager.locationServicesEnabled() else {
            statusLabel.stringValue = "Службы геолокации Mac выключены"
            return
        }

        if let location = locationManager.location,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 10_000,
           abs(location.timestamp.timeIntervalSinceNow) < 300 {
            centerMap(on: location.coordinate)
            return
        }

        isWaitingForMacLocation = true
        locationRequestID += 1
        let requestID = locationRequestID
        statusLabel.stringValue = "Определяю позицию Mac..."

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginMacLocationUpdates()
        case .denied, .restricted:
            isWaitingForMacLocation = false
            statusLabel.stringValue = "Разрешите геопозицию для iOS Location Controller в Системных настройках → Конфиденциальность и безопасность → Службы геолокации"
        @unknown default:
            isWaitingForMacLocation = false
            statusLabel.stringValue = "macOS вернула неизвестный статус разрешения геопозиции"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isWaitingForMacLocation, self.locationRequestID == requestID else { return }
            self.isWaitingForMacLocation = false
            self.locationManager.stopUpdatingLocation()
            self.statusLabel.stringValue = "macOS не определила позицию. Проверьте Wi‑Fi и Службы геолокации, затем нажмите кнопку ещё раз."
        }
    }

    private func beginMacLocationUpdates() {
        guard isWaitingForMacLocation, hasMacLocationAuthorization else { return }
        locationManager.stopUpdatingLocation()
        locationManager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isWaitingForMacLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginMacLocationUpdates()
        case .notDetermined:
            break
        case .denied, .restricted:
            isWaitingForMacLocation = false
            statusLabel.stringValue = "Разрешите геопозицию для iOS Location Controller в Системных настройках → Конфиденциальность и безопасность → Службы геолокации"
        @unknown default:
            isWaitingForMacLocation = false
            statusLabel.stringValue = "macOS вернула неизвестный статус разрешения геопозиции"
        }
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        if let macLocationAnnotation {
            macLocationAnnotation.coordinate = coordinate
        } else {
            let annotation = MKPointAnnotation()
            annotation.title = "Позиция Mac"
            annotation.coordinate = coordinate
            macLocationAnnotation = annotation
            mapView.addAnnotation(annotation)
        }
        mapView.setRegion(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        ), animated: true)
        statusLabel.stringValue = "Карта перемещена к позиции Mac"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isWaitingForMacLocation,
              let location = locations.last(where: { $0.horizontalAccuracy >= 0 }),
              CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        isWaitingForMacLocation = false
        manager.stopUpdatingLocation()
        centerMap(on: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError = error as NSError
        if locationError.domain == kCLErrorDomain && locationError.code == CLError.locationUnknown.rawValue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak manager] in
                guard let self, let manager, self.isWaitingForMacLocation, self.hasMacLocationAuthorization else { return }
                manager.requestLocation()
            }
            return
        }
        isWaitingForMacLocation = false
        manager.stopUpdatingLocation()
        statusLabel.stringValue = "Позиция Mac недоступна: \(error.localizedDescription)"
    }

    @objc private func searchLocation() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            statusLabel.stringValue = "Введите город, улицу или адрес"
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        localSearch?.cancel()
        searchTask?.cancel()
        searchWorkItem?.cancel()

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = mapView.region
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        localSearch = search
        statusLabel.stringValue = "Ищу: \(query)..."

        search.start { [weak self, weak search] response, error in
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation,
                      let search, self.localSearch === search else { return }
                self.localSearch = nil
                if let item = response?.mapItems.first {
                    self.showSearchResult(
                        coordinate: item.placemark.coordinate,
                        name: item.name ?? query,
                        region: nil,
                        usesOpenStreetMap: false
                    )
                } else {
                    self.loadOSMSearch(query: query, generation: generation, appleError: error)
                }
            }
        }
    }

    private func loadOSMSearch(query: String, generation: Int, appleError: Error?) {
        statusLabel.stringValue = "Apple Maps не нашёл место. Ищу через OpenStreetMap..."
        let elapsed = lastOSMSearchDate.map { Date().timeIntervalSince($0) } ?? 2
        let delay = max(0, 1.05 - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.searchWorkItem = nil
            self.lastOSMSearchDate = Date()
            self.startOSMSearchRequest(query: query, generation: generation, appleError: appleError)
        }
        searchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startOSMSearchRequest(query: String, generation: Int, appleError: Error?) {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "accept-language", value: "ru")
        ]
        guard let url = components?.url else {
            statusLabel.stringValue = "Не удалось подготовить поисковый запрос"
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("iOS-Location-Controller/0.2.0 (+https://github.com/Plyshkaa/change-geo-ios)", forHTTPHeaderField: "User-Agent")
        searchTask = routingSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.searchTask = nil
                guard let data, data.count <= 1_000_000, error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let result = try? JSONDecoder().decode([OSMSearchResult].self, from: data).first,
                      let latitude = Double(result.latitude),
                      let longitude = Double(result.longitude) else {
                    self.statusLabel.stringValue = "Ничего не найдено: \(error?.localizedDescription ?? appleError?.localizedDescription ?? query)"
                    return
                }

                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                guard CLLocationCoordinate2DIsValid(coordinate) else {
                    self.statusLabel.stringValue = "Поиск вернул некорректную координату"
                    return
                }
                let region = self.region(from: result.boundingBox, fallback: coordinate)
                self.showSearchResult(
                    coordinate: coordinate,
                    name: result.displayName,
                    region: region,
                    usesOpenStreetMap: true
                )
            }
        }
        searchTask?.resume()
    }

    private func region(from boundingBox: [String]?, fallback coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        guard let boundingBox, boundingBox.count == 4,
              let south = Double(boundingBox[0]), let north = Double(boundingBox[1]),
              let west = Double(boundingBox[2]), let east = Double(boundingBox[3]) else {
            return MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
            )
        }
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: min(90, max(0.02, abs(north - south) * 1.25)),
                longitudeDelta: min(180, max(0.02, abs(east - west) * 1.25))
            )
        )
    }

    private func showSearchResult(
        coordinate: CLLocationCoordinate2D,
        name: String,
        region: MKCoordinateRegion?,
        usesOpenStreetMap: Bool
    ) {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            statusLabel.stringValue = "Поиск вернул некорректную координату"
            return
        }
        if let annotation = searchAnnotation {
            mapView.removeAnnotation(annotation)
        }
        let annotation = MKPointAnnotation()
        annotation.title = "Результат поиска"
        annotation.subtitle = name
        annotation.coordinate = coordinate
        searchAnnotation = annotation
        mapView.addAnnotation(annotation)
        mapView.setRegion(region ?? MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        ), animated: true)
        searchUsesOpenStreetMap = usesOpenStreetMap
        osmAttributionButton.isHidden = !(searchUsesOpenStreetMap || routeUsesOpenStreetMap)
        statusLabel.stringValue = "Найдено: \(name). Нажмите на карте, чтобы выбрать точку."
    }

    private func configureControls() {
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        selectionControl.selectedSegment = 1
        selectionControl.target = self
        selectionControl.action = #selector(selectionChanged)

        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.isContinuous = true

        directionControl.selectedSegment = 0
        directionControl.target = self
        directionControl.action = #selector(directionChanged)

        latitudeField.placeholderString = "Широта"
        longitudeField.placeholderString = "Долгота"
        latitudeField.delegate = self
        longitudeField.delegate = self

        searchField.placeholderString = "Найти город или адрес"
        searchField.target = self
        searchField.action = #selector(searchLocation)
        searchField.sendsSearchStringImmediately = false
        searchField.toolTip = "Введите город, улицу или адрес и нажмите Enter"

        devicePicker.addItem(withTitle: "Проверить подключение")

        updateModeVisibility()
        updateCoordinateLabels()
        updateMap()
    }

    private func makeSidebar() -> NSView {
        let title = NSTextField(labelWithString: "Управление геопозицией")
        title.font = .boldSystemFont(ofSize: 20)

        let subtitle = NSTextField(labelWithString: "Выберите режим и задайте точку на карте")
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping

        let modeLabel = NSTextField(labelWithString: "Режим")
        modeLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let currentCard = makeLocationCard(title: "Начальная точка", value: currentValue, symbol: "location.fill")
        let destinationCard = makeLocationCard(title: "Пункт назначения", value: destinationValue, symbol: "mappin.and.ellipse")

        let selectionLabel = NSTextField(labelWithString: "Клик по карте задаёт")
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let speedLabel = NSTextField(labelWithString: "Скорость")
        speedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let speedRow = NSStackView(views: [speedSlider, speedValue])
        speedRow.orientation = .horizontal
        speedRow.spacing = 8
        speedRow.alignment = .centerY
        speedSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let routeStack = NSStackView(views: [selectionLabel, selectionControl, speedLabel, speedRow, directionControl, distanceValue])
        routeStack.orientation = .vertical
        routeStack.alignment = .leading
        routeStack.spacing = 8
        routeStack.translatesAutoresizingMaskIntoConstraints = false
        routeControls.addSubview(routeStack)
        NSLayoutConstraint.activate([
            routeStack.leadingAnchor.constraint(equalTo: routeControls.leadingAnchor),
            routeStack.trailingAnchor.constraint(equalTo: routeControls.trailingAnchor),
            routeStack.topAnchor.constraint(equalTo: routeControls.topAnchor),
            routeStack.bottomAnchor.constraint(equalTo: routeControls.bottomAnchor),
            selectionControl.widthAnchor.constraint(equalTo: routeStack.widthAnchor),
            directionControl.widthAnchor.constraint(equalTo: routeStack.widthAnchor),
            speedRow.widthAnchor.constraint(equalTo: routeStack.widthAnchor),
            distanceValue.widthAnchor.constraint(equalTo: routeStack.widthAnchor)
        ])

        let pointHint = NSTextField(labelWithString: "Нажмите на карте, чтобы выбрать новую координату.")
        pointHint.textColor = .secondaryLabelColor
        pointHint.maximumNumberOfLines = 2
        pointHint.lineBreakMode = .byWordWrapping
        pointHint.translatesAutoresizingMaskIntoConstraints = false
        pointControls.addSubview(pointHint)
        NSLayoutConstraint.activate([
            pointHint.leadingAnchor.constraint(equalTo: pointControls.leadingAnchor),
            pointHint.trailingAnchor.constraint(equalTo: pointControls.trailingAnchor),
            pointHint.topAnchor.constraint(equalTo: pointControls.topAnchor),
            pointHint.bottomAnchor.constraint(equalTo: pointControls.bottomAnchor)
        ])

        actionButton.target = self
        actionButton.action = #selector(startAction)
        actionButton.bezelStyle = .rounded
        actionButton.isEnabled = false
        let resetButton = NSButton(title: "Сбросить на реальное гео", target: self, action: #selector(clearLocation))
        resetButton.bezelStyle = .rounded
        let devicesButton = NSButton(title: "Обновить устройства", target: self, action: #selector(listDevices))
        devicesButton.bezelStyle = .rounded

        let coordinatesLabel = NSTextField(labelWithString: "Координаты выбранной точки")
        coordinatesLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let coordinateRow = NSStackView(views: [latitudeField, longitudeField])
        coordinateRow.orientation = .horizontal
        coordinateRow.spacing = 8
        coordinateRow.distribution = .fillEqually
        latitudeField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        longitudeField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let statusTitle = NSTextField(labelWithString: "Состояние")
        statusTitle.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping

        let sidebarStack = NSStackView(views: [
            title, subtitle, modeLabel, modeControl, currentCard, destinationCard,
            pointControls, routeControls, actionButton, resetButton, coordinatesLabel,
            coordinateRow, devicePicker, devicesButton, statusTitle, statusLabel
        ])
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 10
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(sidebarStack)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            sidebarStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            sidebarStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            modeControl.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            currentCard.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            destinationCard.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            pointControls.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            routeControls.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            actionButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            resetButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            coordinateRow.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            devicePicker.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            devicesButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor)
        ])
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = container
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])
        return scrollView
    }

    private func makeLocationCard(title: String, value: NSTextField, symbol: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let heading = NSTextField(labelWithString: title)
        heading.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        value.font = .systemFont(ofSize: 13)
        value.maximumNumberOfLines = 2
        value.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [header, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.contentView = stack
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 76).isActive = true
        return box
    }

    @objc private func modeChanged() {
        if session != nil { stopSession() }
        updateModeVisibility()
        updateCoordinateLabels()
        updateMap()
    }

    @objc private func selectionChanged() {
        selection = selectionControl.selectedSegment == 0 ? .start : .end
        showSelectedCoordinate()
        statusLabel.stringValue = selection == .start ? "Выберите начальную точку на карте" : "Выберите конечную точку на карте"
    }

    @objc private func speedChanged() {
        speedValue.stringValue = "\(Int(speedSlider.doubleValue)) км/ч"
    }

    @objc private func directionChanged() {
        if session != nil { stopSession() }
        updateMap()
    }

    private func updateModeVisibility() {
        let route = modeControl.selectedSegment == 1
        routeControls.isHidden = !route
        pointControls.isHidden = route
        actionButton.title = route ? "Запустить маршрут" : "Установить геопозицию"
        actionButton.isEnabled = !deviceIDs.isEmpty && (route ? !routeCoordinates.isEmpty : endCoordinate != nil)
        if !route {
            selection = .end
        }
        showSelectedCoordinate()
    }

    private func showSelectedCoordinate() {
        let coordinate = selection == .start && modeControl.selectedSegment == 1 ? startCoordinate : endCoordinate
        latitudeField.stringValue = coordinate.map { String(format: "%.6f", $0.latitude) } ?? ""
        longitudeField.stringValue = coordinate.map { String(format: "%.6f", $0.longitude) } ?? ""
    }

    private func select(coordinate: CLLocationCoordinate2D) {
        if session != nil { stopSession() }
        if modeControl.selectedSegment == 0 {
            endCoordinate = coordinate
        } else if selection == .start {
            startCoordinate = coordinate
        } else {
            endCoordinate = coordinate
        }
        latitudeField.stringValue = String(format: "%.6f", coordinate.latitude)
        longitudeField.stringValue = String(format: "%.6f", coordinate.longitude)
        updateCoordinateLabels()
        updateMap()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let latitude = Double(latitudeField.stringValue.replacingOccurrences(of: ",", with: ".")),
              let longitude = Double(longitudeField.stringValue.replacingOccurrences(of: ",", with: ".")),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            statusLabel.stringValue = "Введите широту от -90 до 90 и долготу от -180 до 180"
            return
        }
        select(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private func updateCoordinateLabels() {
        let start = startCoordinate
        currentValue.stringValue = start.map { formatCoordinate($0) } ?? "Выберите точку на карте"
        destinationValue.stringValue = formatCoordinate(endCoordinate)
        distanceValue.stringValue = routeCoordinates.isEmpty ? "Расстояние: -" : String(format: "Расстояние: %.2f км", routeDistance / 1000)
    }

    private func formatCoordinate(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "Выберите точку на карте" }
        return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func updateMap() {
        routeGeneration += 1
        let generation = routeGeneration
        directions?.cancel()
        directions = nil
        routeTask?.cancel()
        routeTask = nil
        osmRouteWorkItem?.cancel()
        osmRouteWorkItem = nil
        routeUsesOpenStreetMap = false
        osmAttributionButton.isHidden = !searchUsesOpenStreetMap
        routeCoordinates = []
        routeDistance = 0
        if let routeOverlay {
            mapView.removeOverlay(routeOverlay)
            self.routeOverlay = nil
        }
        if let routeOutlineOverlay {
            mapView.removeOverlay(routeOutlineOverlay)
            self.routeOutlineOverlay = nil
        }
        if let startAnnotation {
            mapView.removeAnnotation(startAnnotation)
        }
        if let endAnnotation {
            mapView.removeAnnotation(endAnnotation)
        }

        if let start = startCoordinate, modeControl.selectedSegment == 1 {
            let annotation = MKPointAnnotation()
            annotation.coordinate = start
            annotation.title = "Начальная точка"
            startAnnotation = annotation
            mapView.addAnnotation(annotation)
        }
        if let end = endCoordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = end
            annotation.title = "Пункт назначения"
            endAnnotation = annotation
            mapView.addAnnotation(annotation)
        }

        if let focus = endCoordinate ?? startCoordinate, mapView.region.span.latitudeDelta > 30 {
            mapView.setRegion(MKCoordinateRegion(
                center: focus,
                span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
            ), animated: false)
        }
        guard modeControl.selectedSegment == 1, let start = startCoordinate, let end = endCoordinate else {
            actionButton.isEnabled = !deviceIDs.isEmpty && modeControl.selectedSegment == 0 && endCoordinate != nil
            updateCoordinateLabels()
            return
        }

        actionButton.isEnabled = false
        statusLabel.stringValue = "Строю маршрут по дорогам..."
        let request = MKDirections.Request()
        if #available(macOS 26.0, *) {
            request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
        } else {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        }
        request.transportType = .automobile
        let task = MKDirections(request: request)
        directions = task
        task.calculate { [weak self] response, error in
            guard let self, self.routeGeneration == generation else { return }
            self.directions = nil
            guard let path = response?.routes.first else {
                self.loadOSMRoute(from: start, to: end, generation: generation, appleError: error)
                return
            }
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: path.polyline.pointCount)
            path.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
            self.displayRoute(coordinates, distance: path.distance)
        }
    }

    private func loadOSMRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        generation: Int,
        appleError: Error?
    ) {
        statusLabel.stringValue = "Apple Maps недоступен. Запрашиваю маршрут OSM..."
        let positions = String(format: "%.6f,%.6f;%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), start.longitude, start.latitude, end.longitude, end.latitude)
        guard let url = URL(string: "https://routing.openstreetmap.de/routed-car/route/v1/driving/\(positions)?overview=full&geometries=geojson") else {
            statusLabel.stringValue = "Некорректные координаты маршрута"
            return
        }
        let elapsed = lastOSMRequestDate.map { Date().timeIntervalSince($0) } ?? 2
        let delay = max(0, 1.05 - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.routeGeneration == generation else { return }
            self.osmRouteWorkItem = nil
            self.lastOSMRequestDate = Date()
            self.startOSMRouteRequest(url: url, generation: generation, appleError: appleError)
        }
        osmRouteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startOSMRouteRequest(url: URL, generation: Int, appleError: Error?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("iOS-Location-Controller/0.2.0 (+https://github.com/Plyshkaa/change-geo-ios)", forHTTPHeaderField: "User-Agent")
        routeTask = routingSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.routeGeneration == generation else { return }
                self.routeTask = nil
                guard let data,
                      data.count <= 20_000_000,
                      error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let response = try? JSONDecoder().decode(OSRMResponse.self, from: data),
                      response.code == "Ok",
                      let route = response.routes.first,
                      route.distance.isFinite,
                      route.distance >= 0,
                      (2...100_000).contains(route.geometry.coordinates.count) else {
                    self.actionButton.isEnabled = false
                    self.statusLabel.stringValue = "Не удалось построить дорогу: \(error?.localizedDescription ?? appleError?.localizedDescription ?? "маршрут не найден")"
                    return
                }
                let coordinates = route.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count == 2,
                          pair[0].isFinite, pair[1].isFinite,
                          (-180...180).contains(pair[0]),
                          (-90...90).contains(pair[1]) else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                guard coordinates.count == route.geometry.coordinates.count else {
                    self.actionButton.isEnabled = false
                    self.statusLabel.stringValue = "Сервис маршрутов вернул некорректные координаты"
                    return
                }
                self.displayRoute(coordinates, distance: route.distance, usesOpenStreetMap: true)
            }
        }
        routeTask?.resume()
    }

    private func displayRoute(_ coordinates: [CLLocationCoordinate2D], distance: Double, usesOpenStreetMap: Bool = false) {
        guard coordinates.count > 1 else {
            statusLabel.stringValue = "Дорога не найдена"
            actionButton.isEnabled = false
            return
        }
        routeCoordinates = coordinates
        routeDistance = distance
        var outlinePoints = coordinates
        let outline = MKPolyline(coordinates: &outlinePoints, count: outlinePoints.count)
        routeOutlineOverlay = outline
        mapView.addOverlay(outline)

        var routePoints = coordinates
        let polyline = MKPolyline(coordinates: &routePoints, count: routePoints.count)
        routeOverlay = polyline
        mapView.addOverlay(polyline)
        mapView.setVisibleMapRect(polyline.boundingMapRect, edgePadding: NSEdgeInsets(top: 58, left: 58, bottom: 58, right: 58), animated: true)
        actionButton.isEnabled = !deviceIDs.isEmpty
        routeUsesOpenStreetMap = usesOpenStreetMap
        osmAttributionButton.isHidden = !(routeUsesOpenStreetMap || searchUsesOpenStreetMap)
        updateCoordinateLabels()
        statusLabel.stringValue = usesOpenStreetMap ? "Маршрут готов · OpenStreetMap" : "Маршрут готов"
    }

    private func startMovementAnimation() {
        stopMovementAnimation(removeAnnotation: true)
        guard routeCoordinates.count > 1 else { return }

        movementCoordinates = routeCoordinates
        movementCumulativeDistances = [0]
        var total: CLLocationDistance = 0
        for (from, to) in zip(routeCoordinates, routeCoordinates.dropFirst()) {
            total += CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            movementCumulativeDistances.append(total)
        }
        guard total > 0 else { return }

        movementTotalDistance = total
        movementSpeedMetersPerSecond = max(0.3, speedSlider.doubleValue / 3.6)
        movementReturnsToStart = directionControl.selectedSegment == 1
        movementStartDate = Date()

        let annotation = MKPointAnnotation()
        annotation.title = "Текущее положение на маршруте"
        annotation.coordinate = routeCoordinates[0]
        movementAnnotation = annotation
        mapView.addAnnotation(annotation)

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateMovementAnimation()
        }
        movementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateMovementAnimation() {
        guard let startDate = movementStartDate,
              movementTotalDistance > 0,
              let annotation = movementAnnotation else {
            stopMovementAnimation(removeAnnotation: false)
            return
        }

        let travelled = max(0, Date().timeIntervalSince(startDate) * movementSpeedMetersPerSecond)
        let animationDistance = movementReturnsToStart ? movementTotalDistance * 2 : movementTotalDistance
        let finished = travelled >= animationDistance
        let clamped = min(travelled, animationDistance)
        let routeDistance = clamped <= movementTotalDistance
            ? clamped
            : max(0, movementTotalDistance * 2 - clamped)
        annotation.coordinate = coordinateOnMovementRoute(at: routeDistance)

        if finished {
            movementTimer?.invalidate()
            movementTimer = nil
            movementStartDate = nil
        }
    }

    private func coordinateOnMovementRoute(at distance: CLLocationDistance) -> CLLocationCoordinate2D {
        guard movementCoordinates.count > 1,
              movementCoordinates.count == movementCumulativeDistances.count else {
            return movementCoordinates.first ?? CLLocationCoordinate2D()
        }
        if distance <= 0 { return movementCoordinates[0] }
        if distance >= movementTotalDistance { return movementCoordinates[movementCoordinates.count - 1] }

        var lower = 1
        var upper = movementCumulativeDistances.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if movementCumulativeDistances[middle] < distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let toIndex = lower
        let fromIndex = toIndex - 1
        let segmentStart = movementCumulativeDistances[fromIndex]
        let segmentLength = movementCumulativeDistances[toIndex] - segmentStart
        let fraction = segmentLength > 0 ? (distance - segmentStart) / segmentLength : 0
        let from = movementCoordinates[fromIndex]
        let to = movementCoordinates[toIndex]
        return CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
    }

    private func stopMovementAnimation(removeAnnotation: Bool) {
        movementTimer?.invalidate()
        movementTimer = nil
        movementStartDate = nil
        movementCoordinates = []
        movementCumulativeDistances = []
        movementTotalDistance = 0
        if removeAnnotation, let movementAnnotation {
            mapView.removeAnnotation(movementAnnotation)
            self.movementAnnotation = nil
        }
    }

    @objc private func startAction() {
        if modeControl.selectedSegment == 0 {
            guard let end = endCoordinate else {
                statusLabel.stringValue = "Сначала выберите точку на карте"
                return
            }
            stopSession()
            var arguments = ["set", String(end.latitude), String(end.longitude)]
            appendUDID(to: &arguments)
            startSession(arguments: arguments, status: "Точка установлена; сессия активна")
            return
        }

        guard !routeCoordinates.isEmpty else {
            statusLabel.stringValue = "Сначала выберите начало и конец и дождитесь построения маршрута"
            return
        }

        do {
            let gpx = try makeGPX(coordinates: routeCoordinates)
            stopSession()
            temporaryGPXURL = gpx
            var arguments = ["play", gpx.path]
            appendUDID(to: &arguments)
            startSession(arguments: arguments, status: "Маршрут запущен")
            if session != nil {
                startMovementAnimation()
            }
        } catch {
            statusLabel.stringValue = "Не удалось создать маршрут: \(error.localizedDescription)"
        }
    }

    @objc private func clearLocation() {
        stopSession()
        var arguments = ["clear"]
        appendUDID(to: &arguments)
        startSession(arguments: arguments, status: "Возвращаю реальный GPS...")
        endCoordinate = nil
        startCoordinate = nil
        showSelectedCoordinate()
        updateCoordinateLabels()
        updateMap()
    }

    @objc private func listDevices() {
        let process = Process()
        process.executableURL = backendURL
        process.arguments = backendArguments(["devices", "--usb"])
        process.currentDirectoryURL = backendURL.deletingLastPathComponent()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        statusLabel.stringValue = "Проверяю подключение..."
        process.terminationHandler = { [weak self] process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self else { return }
                guard process.terminationStatus == 0,
                      let devices = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                    self.statusLabel.stringValue = "Не удалось получить список USB-устройств"
                    return
                }
                self.devicePicker.removeAllItems()
                self.deviceIDs = []
                for device in devices {
                    guard let id = device["UniqueDeviceID"] as? String else { continue }
                    let name = device["DeviceName"] as? String ?? "iPhone"
                    let version = device["ProductVersion"] as? String ?? ""
                    self.devicePicker.addItem(withTitle: "\(name) · iOS \(version)")
                    self.deviceIDs.append(id)
                }
                if self.deviceIDs.isEmpty {
                    self.devicePicker.addItem(withTitle: "iPhone не найден")
                }
                self.actionButton.isEnabled = !self.deviceIDs.isEmpty && (self.modeControl.selectedSegment == 0 || !self.routeCoordinates.isEmpty)
                self.statusLabel.stringValue = self.deviceIDs.isEmpty ? "Подключите iPhone по USB" : "Устройство подключено"
            }
        }
        do {
            try process.run()
        } catch {
            statusLabel.stringValue = "Не удалось проверить устройства: \(error.localizedDescription)"
        }
    }

    private func appendUDID(to arguments: inout [String]) {
        let index = devicePicker.indexOfSelectedItem
        if deviceIDs.indices.contains(index) {
            arguments.append(contentsOf: ["--udid", deviceIDs[index]])
        }
    }

    private func startSession(arguments: [String], status: String) {
        guard FileManager.default.isExecutableFile(atPath: backendURL.path) else {
            statusLabel.stringValue = "Не найден backend: \(backendURL.path)"
            return
        }

        let process = Process()
        process.executableURL = backendURL
        process.arguments = backendArguments(arguments)
        process.currentDirectoryURL = backendURL.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    self?.statusLabel.stringValue = text
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard self?.session === process else { return }
                let wasAnimatingRoute = self?.movementAnnotation != nil
                self?.session = nil
                self?.removeTemporaryGPX()
                self?.stopMovementAnimation(removeAnnotation: false)
                if process.terminationStatus != 0 {
                    self?.statusLabel.stringValue = "Backend завершился с кодом \(process.terminationStatus)"
                } else if wasAnimatingRoute {
                    self?.statusLabel.stringValue = "Маршрут завершён"
                }
            }
        }

        do {
            try process.run()
            session = process
            statusLabel.stringValue = status
        } catch {
            statusLabel.stringValue = "Не удалось запустить backend: \(error.localizedDescription)"
        }
    }

    private func stopSession() {
        stopMovementAnimation(removeAnnotation: true)
        if let session, session.isRunning {
            session.interrupt()
            session.waitUntilExit()
        }
        self.session = nil
        removeTemporaryGPX()
    }

    private func removeTemporaryGPX() {
        guard let temporaryGPXURL else { return }
        try? FileManager.default.removeItem(at: temporaryGPXURL)
        self.temporaryGPXURL = nil
    }

    private func cleanupStaleTemporaryGPX() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("ios-location-route-") && file.pathExtension == "gpx" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func makeGPX(coordinates: [CLLocationCoordinate2D]) throws -> URL {
        guard coordinates.count > 1 else {
            throw NSError(domain: "LocationController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Маршрут не содержит точек"])
        }
        let segments = zip(coordinates, coordinates.dropFirst()).map { from, to in
            CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        }
        let distance = segments.reduce(0, +)
        let speedMetersPerSecond = max(0.3, speedSlider.doubleValue / 3.6)
        let spacing = max(speedMetersPerSecond * 2, distance / 5000)
        let sampleCount = max(2, Int(ceil(distance / spacing)) + 1)
        var points: [(CLLocationCoordinate2D, TimeInterval)] = []
        var segmentIndex = 0
        var segmentStartDistance = 0.0
        for index in 0..<sampleCount {
            let target = distance * Double(index) / Double(sampleCount - 1)
            while segmentIndex < segments.count - 1 && segmentStartDistance + segments[segmentIndex] < target {
                segmentStartDistance += segments[segmentIndex]
                segmentIndex += 1
            }
            let segmentDistance = segments[segmentIndex]
            let fraction = segmentDistance > 0 ? (target - segmentStartDistance) / segmentDistance : 0
            let from = coordinates[segmentIndex]
            let to = coordinates[segmentIndex + 1]
            points.append((CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                longitude: from.longitude + (to.longitude - from.longitude) * fraction
            ), target / speedMetersPerSecond))
        }
        if directionControl.selectedSegment == 1 {
            for index in stride(from: sampleCount - 2, through: 0, by: -1) {
                let point = points[index]
                points.append((point.0, (2 * distance - point.1 * speedMetersPerSecond) / speedMetersPerSecond))
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startDate = Date()
        let trackPoints = points.map { point, offset in
            let time = formatter.string(from: startDate.addingTimeInterval(offset))
            return "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><time>\(time)</time></trkpt>"
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iOS Location Controller" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Generated route</name><trkseg>
        \(trackPoints)
          </trkseg></trk>
        </gpx>
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-location-route-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        if let outline = routeOutlineOverlay, polyline === outline {
            renderer.strokeColor = NSColor.black.withAlphaComponent(0.72)
            renderer.lineWidth = 10
        } else {
            renderer.strokeColor = .systemPink
            renderer.lineWidth = 6
        }
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation { return nil }
        let identifier: String
        switch annotation.title ?? nil {
        case "Начальная точка": identifier = "start"
        case "Позиция Mac": identifier = "mac"
        case "Текущее положение на маршруте": identifier = "movement"
        case "Результат поиска": identifier = "search"
        default: identifier = "end"
        }
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.animatesWhenAdded = true
        switch identifier {
        case "start":
            view.markerTintColor = .systemGreen
            view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
        case "mac":
            view.markerTintColor = .systemBlue
            view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
        case "movement":
            view.markerTintColor = .systemOrange
            view.glyphImage = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
        case "search":
            view.markerTintColor = .systemPurple
            view.glyphImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        default:
            view.markerTintColor = .systemRed
            view.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
        }
        return view
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
