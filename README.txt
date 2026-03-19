Code 1 – Repeating scheduler
Controls time-resolved image acquisition during cultivation. The script periodically triggers Code 2 at defined intervals.

Code 2 – Image acquisition routine
Executes a single Image Acquisition Event (IAE). Activates illumination, applies a short delay, captures multiple images, verifies complete data transfer, and stores only valid images.

Code 3 – In situ morphology Analysis (image folder)
Processes reactor images to quantify morphological parameters. Includes preprocessing, cylindrical rectification, ROI selection, segmentation, watershed-based object separation, object filtering, and evaluation of projected object area (POA) and object count.

Code 4 – Morphology control visualization (single image)
Generates stepwise visualizations of the image analysis pipeline for morphology. Displays intermediate processing stages (e.g., rectified image, ROI, binarization, segmentation, filtering) for validation and debugging.

Code 5 – Luminosity analysis (image folder)
Calculates mean pixel intensity within defined ROIs as a measure of scattered light intensity. Outputs averaged luminosity values per image and per IAE for biomass estimation.

The script includes three ROI configurations: one ROI set for the POM sphere model system and two ROI sets for fermentation experiments, enabling exclusion of disturbed regions.

Code 6 – Luminosity control visualization (single image)
Visualizes ROI placement and corresponding pixel intensity values on example images. Used to validate luminosity-based analysis and illustrate differences between conditions.

Code 7 – Ex situ image analysis (image folder)
Analyzes flatbed scanner images of sampled biomass. Includes Petri dish detection, masking, segmentation of pellets, object filtering, and calculation of POA as a reference method for morphology.

camera_Calibration_Parameters – Camera calibration data
Contains calibration parameters used for cylindrical rectification of the curved bioreactor surface, enabling transformation into a planar image representation. These parameters are specific to the optical setup (camera, lens, distance, and reactor geometry) used in this study and must be re-derived for different experimental configurations.