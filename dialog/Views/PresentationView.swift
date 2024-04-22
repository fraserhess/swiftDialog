//
//  PresentationView.swift
//  Dialog
//
//  Created by Bart E Reardon on 5/3/2024.
//

import SwiftUI
import MarkdownUI

struct PresentationView: View {

    @ObservedObject var observedData: DialogUpdatableContent

    var messageColor: Color
    var backgroundColour: Color
    //Color(.accentColor).isDark ? Color.white : Color.black

    init(observedData: DialogUpdatableContent) {
        self.observedData = observedData
        self.backgroundColour = Color(argument: observedData.args.watermarkImage.value.components(separatedBy: "=").last ?? "accent")
        self.messageColor = self.backgroundColour.isDark ? Color.white : Color.black
    }

    var body: some View {
        GeometryReader { content in
            Color.clear.onAppear {
                if !observedData.args.windowResizable.present {
                    observedData.appProperties.windowWidth = content.size.width
                }
            }
            VStack {
                // title
                //TitleView(observedData: observedData)
                // content
                HStack {
                    if observedData.args.mainImage.present {
                        ImageView(imageArray: observedData.imageArray, captionArray: observedData.appProperties.imageCaptionArray, autoPlaySeconds: observedData.args.autoPlay.value.floatValue(), showControls: false, clipRadius: 0)
                            .aspectRatio(contentMode: .fit)
                            //.scaledToFill()
                            //.clipped()
                            //.frame(width: content.size.width*0.3)
                    } else if observedData.args.webcontent.present {
                        WebContentView(observedDialogContent: observedData, url: observedData.args.webcontent.value)
                            .frame(maxWidth: content.size.width*0.3)
                    } else {
                        ZStack {
                            if observedData.args.watermarkImage.value.range(of: "colo[u]?r=", options: .regularExpression) != nil {
                                SolidColourView(colourValue: observedData.args.watermarkImage.value)
                            } else {
                                SolidColourView(colourValue: "accent")
                            }

                            Markdown(observedData.args.messageOption.value, baseURL: URL(string: "http://"))
                                .multilineTextAlignment(observedData.appProperties.messageAlignment)
                                .markdownTheme(.sdMarkdown)
                                .markdownTextStyle {
                                    FontSize(appvars.messageFontSize)
                                }
                                .accessibilityHint(observedData.args.messageOption.value)
                                .focusable(false)
                                .markdownTextStyle {
                                    FontSize(appvars.messageFontSize)
                                    ForegroundColor(messageColor)
                                }
                                .truncationMode(.tail)
                                .padding(.all, 15)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: content.size.width*0.3)
                    }

                    // list view
                    ListView(observedDialogContent: observedData, clipRadius: 0)
                }

                // footer
                VStack {
                    ProgressView(value: observedData.progressValue, total: observedData.progressTotal)
                        .progressViewStyle(TaskProgressViewStyle())
                        .padding(.horizontal, 10)
                    Text(observedData.args.progressText.value)
                        .lineLimit(1)
                    // Buttons
                    ButtonView(observedDialogContent: observedData)
                        .padding(.leading, observedData.appProperties.sidePadding)
                        .padding(.trailing, observedData.appProperties.sidePadding)
                        .padding(.bottom, observedData.appProperties.bottomPadding)
                        .border(observedData.appProperties.debugBorderColour, width: 2)
                }
            }
            .edgesIgnoringSafeArea(.top)
        }
    }
}

