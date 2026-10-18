# Gantry Vision: observation and evaluation data

[Polski](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Gantry-Vision-PL.md) · [Contents](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

Vision observes the camera while printing and reports suspected problems. Its result is a reason to inspect the print, not a certificate of quality.

## Enable observation

1. Open printer Details and check the camera and lighting.
2. Enable print watching in **Settings → Advanced**.
3. Set the observation interval and sensitivity where available.
4. Review initial reports on real prints. A dark or obscured image cannot support a reliable judgement.

Warnings require repeated observations. Image quality, lighting, sensitivity and observation interval all affect the reliability of a result.

## Choose a model

The default **Gantry Vision Fast** is bundled with the app. **Other file…** selects a custom model in a format supported by your installation. Its name and recommended sensitivity come from metadata. Gantry reports missing dependencies or an invalid model.

A custom ONNX model needs compatible `model.json` metadata: RGB NCHW 224 × 224 input and a label list. Not every ONNX file is compatible with the adapter. Comparison with labelled frames and model weights are separate sources of information.

Experimental weights are not automatically downloaded or included in installers. There is no verified universal accuracy percentage for your camera.

## Label what you can see

Use **Mark defect…** in Details and select the actual label. Correct prints are as useful as failures. If the toolhead obscures the object, choose a clear frame instead of guessing.

Human labels remain distinct from model predictions. Saving or exporting data does not automatically change network weights. Comparison with local frames is a separate mechanism and does not train model weights.

## Archives and evaluation

**Export Vision data…** creates a ZIP of observations and labelled images. Set the local storage limit in Advanced; exceeding it may remove the oldest data.

While observation is active, first-layer, 25%, 50%, 75% and closing images may be saved. Joining a print halfway cannot recreate earlier stages. The closing image is the latest available frame, including interrupted prints.

Compare false alarms per printing hour and detection of confirmed failures, rather than the model confidence score alone. A `finished` state is not human confirmation of a defect-free print.

Analysis and archives stay local. Separately enabled camera viewing on own hosting can transfer images to that hosting; this is a web function, not Vision training.

## Bundled models and confirmed problems

The default **Gantry Vision Fast** has `ok`, `spaghetti` and `detached` classes. The previous Gantry Vision remains selectable. **Other file…** selects a compatible custom model, and the recommended sensitivity threshold comes from model metadata. Real detachments still lack independent validation; the class uses synthetic detachment examples.

Local trial variants, including Infill, require selecting a separate file. Results on a local frame set are not a universal accuracy measure and do not automatically change installer models.

A user-confirmed defect can create a problem with a photo in **Maintenance & service**. A model alarm alone does not create a report. This keeps human confirmation separate from a prediction.

## Moonraker camera orientation

Gantry now respects 0°/90°/180°/270° rotation and horizontal/vertical flips from Moonraker webcam configuration. Orientation is applied before the frame is shared with other previews and still-image consumers, including web viewing and camera-based tools. This fixes ignored configuration that could show printers such as Artillery upside down; without configured metadata, the app does not guess rotation by brand.

Bundled Fast ONNX embeds ImageNet normalization. The adapter passes RGB / 255 without normalizing twice (`input.normalization: embedded`). A custom model needs correct normalization metadata. Technical format compatibility is not a failure-detection accuracy measurement.


## Dark chamber and alarm photos

A dark-camera notice applies during active printing after layers begin. It clears on pause, completion, interruption, job change or visibility recovery without removing unrelated warnings.

A Vision notification can include the exact frame that triggered it. Notification photos can be enabled per printer. Configure an external camera in [Printer settings and tools](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Printer-tools-EN.md).
