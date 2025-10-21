//
//  ConstructionKitView.swift
//  dialog
//
//  Created by Bart Reardon on 29/6/2022.
//

import SwiftUI
import SwiftyJSON

var jsonFormattedOutout: String = ""

struct LabelView: View {
    var label: String
    var body: some View {
        VStack {
            Divider()
            HStack {
                Text(label)
                    .fontWeight(.bold)
                Spacer()
            }
        }
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack {
            ZStack {
                IconView(image: "default")
                //Image(systemName: "bubble.left.circle.fill")
                //    .resizable()

                IconView(image: "sf=wrench.and.screwdriver.fill", alpha: 0.5, defaultColour: "white")
            }
            .frame(width: 150, height: 150)
            
            Text("ck-welcome".localized)
                .font(.largeTitle)
            Divider()
            Text("ck-welcomeinfo".localized)
                .foregroundColor(.secondary)
        }
    }
}

struct JSONView: View {
    @ObservedObject var observedDialogContent: DialogUpdatableContent

    @State private var jsonText: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    private func exportJSON(debug: Bool = false) -> String {
        var json = JSON()
        var jsonDEBUG = JSON()

        // copy modifyable objects into args
        observedDialogContent.args.iconSize.value = "\(observedDialogContent.iconSize)"
        observedDialogContent.args.windowWidth.value = "\(observedDialogContent.appProperties.windowWidth)"
        observedDialogContent.args.windowHeight.value = "\(observedDialogContent.appProperties.windowHeight)"

        let mirroredAppArguments = Mirror(reflecting: observedDialogContent.args)
        for (_, attr) in mirroredAppArguments.children.enumerated() {
            if let propertyValue = attr.value as? CommandlineArgument {
                if ["builder", "debug"].contains(propertyValue.long) { continue } 
                if propertyValue.present { //}&& propertyValue.value != "" {
                    if propertyValue.value != "" {
                        json[propertyValue.long].string = propertyValue.value
                    } else if propertyValue.isbool {
                        json[propertyValue.long].string = "\(propertyValue.present)"
                    }
                }
                jsonDEBUG[propertyValue.long].string = propertyValue.value
                jsonDEBUG["\(propertyValue.long)-present"].bool = propertyValue.present
            }
        }

        if observedDialogContent.listItemsArray.count > 0 {
            json[appArguments.listItem.long].arrayObject = Array(repeating: 0, count: observedDialogContent.listItemsArray.count)
            for index in 0..<observedDialogContent.listItemsArray.count {
                if observedDialogContent.listItemsArray[index].title.isEmpty {
                    observedDialogContent.listItemsArray[index].title = "Item \(index)"
                }
                // print(observedDialogContent.listItemsArray[i].dictionary)
                json[appArguments.listItem.long][index].dictionaryObject = observedDialogContent.listItemsArray[index].dictionary
            }
        }
        
        if observedDialogContent.textFieldArray.count > 0 {
            json[appArguments.textField.long].arrayObject = Array(repeating: 0, count: observedDialogContent.textFieldArray.count)
            for index in 0..<observedDialogContent.textFieldArray.count {
                json[appArguments.textField.long][index].dictionaryObject = observedDialogContent.textFieldArray[index].dictionary
            }
        }

        if observedDialogContent.imageArray.count > 0 {
            json[appArguments.mainImage.long].arrayObject = Array(repeating: 0, count: observedDialogContent.imageArray.count)
            for index in 0..<observedDialogContent.imageArray.count {
                json[appArguments.mainImage.long][index].dictionaryObject = observedDialogContent.imageArray[index].dictionary
            }
        }

        // message font stuff
        if observedDialogContent.appProperties.messageFontColour != .primary {
            json[appArguments.messageFont.long].dictionaryObject = ["colour": observedDialogContent.appProperties.messageFontColour.hexValue]
        }

        if observedDialogContent.appProperties.titleFontColour != .primary {
            json[appArguments.titleFont.long].dictionaryObject = ["colour": observedDialogContent.appProperties.titleFontColour.hexValue]
        }

        if observedDialogContent.appProperties.buttonSize != .regular {
            json[appArguments.buttonSize.long].string = observedDialogContent.args.buttonSize.value
        }

        // convert the JSON to a raw String
        jsonFormattedOutout = json.rawString() ?? "json is nil"

        if debug {
            jsonFormattedOutout = jsonDEBUG.rawString() ?? ""
        }
        return jsonFormattedOutout
    }

    init (observedDialogContent: DialogUpdatableContent) {
        self.observedDialogContent = observedDialogContent
    }

    func saveToFile(_ content: String) {
            let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = "file.json"
            savePanel.message = "Choose a location to save the file"
            
            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        alertMessage = "File saved successfully!"
                        showAlert = true
                    } catch {
                        alertMessage = "Failed to save file: \(error.localizedDescription)"
                        showAlert = true
                    }
                }
            }
        }
    
    var body: some View {
        ScrollView {
            HStack {
                Button("Regenerate") {
                    jsonText = exportJSON()
                }
                Button("Copy to clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSString(string: exportJSON())])
                }
                Button("Save File") {
                    saveToFile(exportJSON())
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.leading, 10)
            Divider()
            HStack {
                Text(jsonText)
                Spacer()
            }
            .padding(.top, 10)
            .padding(.leading, 10)
            .alert("Save Status", isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            
            Spacer()
            
        }
        .onAppear {
            jsonText = exportJSON()
        }
    }
}

struct ConstructionKitView: View {

    @ObservedObject var observedData: DialogUpdatableContent

    init(observedDialogContent: DialogUpdatableContent) {
        self.observedData = observedDialogContent

        // mark all standard fields visible
        observedDialogContent.args.titleOption.present = true
        observedDialogContent.args.titleFont.present = true
        observedDialogContent.args.messageOption.present = true
        observedDialogContent.args.messageOption.present = true
        observedDialogContent.args.iconOption.present = true
        observedDialogContent.args.iconSize.present = true
        observedDialogContent.args.button1TextOption.present = true
        observedDialogContent.args.windowWidth.present = true
        observedDialogContent.args.windowHeight.present = true
        observedDialogContent.args.movableWindow.present = true

    }

    public func showConstructionKit() {

        var window: NSWindow!
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
               styleMask: [.titled, .closable, .miniaturizable, .resizable],
               backing: .buffered, defer: false)
        window.title = "swiftDialog Construction Kit"
        window.makeKeyAndOrderFront(self)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ConstructionKitView(observedDialogContent: observedData))
        placeWindow(window, size: CGSize(width: 700,
                                         height: 900), vertical: .center, horozontal: .right, offset: 10)
    }

    var body: some View {

        NavigationView {
            List {
                Section(header: Text("ck-basic".localized)) {
                    NavigationLink(destination: CKTitleView(observedDialogContent: observedData)) {
                        Text("Title Bar".localized)
                    }
                    NavigationLink(destination: CKWindowProperties(observedDialogContent: observedData)) {
                        Text("ck-window".localized)
                    }
                    NavigationLink(destination: CKIconView(observedDialogContent: observedData)) {
                        Text("ck-icon".localized)
                    }
                    NavigationLink(destination: CKSidebarView(observedDialogContent: observedData)) {
                        Text("ck-sidebar".localized)
                    }
                    NavigationLink(destination: CKButtonView(observedDialogContent: observedData)) {
                        Text("ck-buttons".localized)
                    }
                }
                Section(header: Text("Data Entry")) {
                    NavigationLink(destination: CKTextEntryView(observedDialogContent: observedData)) {
                        Text("Text Fields".localized)
                    }
                    NavigationLink(destination: CKTextEntryView(observedDialogContent: observedData)) {
                        Text("Select Lists".localized)
                    }
                    NavigationLink(destination: CKTextEntryView(observedDialogContent: observedData)) {
                        Text("Checkboxes".localized)
                    }
                }
                Section(header: Text("ck-advanced".localized)) {
                    NavigationLink(destination: CKListView(observedDialogContent: observedData)) {
                        Text("ck-listitems".localized)
                    }
                    NavigationLink(destination: CKImageView(observedDialogContent: observedData)) {
                        Text("ck-images".localized)
                    }
                    NavigationLink(destination: CKMediaView(observedDialogContent: observedData)) {
                        Text("ck-media".localized)
                    }
                }
                Spacer()
                Section(header: Text("ck-output".localized)) {
                    NavigationLink(destination: JSONView(observedDialogContent: observedData) ) {
                        Text("ck-jsonoutput".localized)
                    }
                }
            }
            .padding(10)

            WelcomeView()
        }
        .listStyle(SidebarListStyle())
        //.frame(minWidth: 800, height: 800)
        Divider()
        ZStack {
            Spacer()
            HStack {
                Button("ck-quit".localized) {
                    quitDialog(exitCode: appDefaults.exit0.code)
                }
                Spacer()
                .disabled(false)
                Button("ck-exportcommand".localized) {}
                    .disabled(true)
            }
        }
        .padding(20)
    }
}
