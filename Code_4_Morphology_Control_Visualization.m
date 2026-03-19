%% ========================================================================
%  SINGLE-IMAGE PELLET ANALYSIS PIPELINE
%  ========================================================================
%
%  SHORT SUMMARY:
%  This script analyzes one grayscale image containing round objects.
%  It enhances contrast (CLAHE), segments candidate pellets (adaptive
%  threshold), splits touching pellets (opening + h-minima watershed),
%  filters regions by geometry and intensity, measures area and diameter
%  in millimeters, and exports a results table (Excel) and an overlay PNG.
%  During execution, several control visualizations are generated,
%  providing direct feedback on parameter changes.
%
%  INPUTS (user-configurable):
%    - bild_pfad   : Full file path to the input BMP image (grayscale or RGB)
%    - export_dir  : Folder for saving the Excel and PNG overlay
%    - Parameters  : Thresholds, geometric constraints, ROI limits
%
%  OUTPUTS:
%    - Excel (.xlsx): One row per accepted pellet + per-image median diameter
%    - PNG overlay  : Visual check of the segmentation/accepted contours
%    - Console logs : Paths, counts, and export success/warnings
%
%% ========================================================================

%% STEP 1: Setup & Parameters
clc; clear; close all;

bild_pfad  = 'PATH_TO_INPUT_IMAGE.bmp';
export_dir = 'PATH_TO_EXPORT_FOLDER';
if ~exist(export_dir, 'dir'), mkdir(export_dir); end

% >>> Load camera calibration parameters <<<
% Adjust the path to your saved cameraParams file:
params_path = 'PATH_TO_CAMERA_PARAMS_FILE\cameraParams_Bildentzerrung.mat';
S = load(params_path, 'cameraParams');
cameraParams = S.cameraParams;
fprintf('cameraParams loaded from: %s\n', params_path);

% Timestamp for consistent file names
timestamp  = datestr(now,'yyyymmdd_HHMMSS');

% Title switch (prevents white bars from title())
SHOW_TITLES = false;
mytitle     = @(s) (SHOW_TITLES && title(s));

% Parameters
Abstand_cm           = 178;
Skalierungsfaktor    = 5.02 / 12;
min_area_mm2         = 0.5;
max_mean_intensity   = 160;
max_std_intensity    = 60;
max_aspect_ratio     = 2;
max_eccentricity     = 0.95;
rundheit_schwelle    = 0.5;
adaptive_sensitivity = 0.56;

% Regional mask (clipped per image to valid bounds)
x_start = 126; x_end = 1330;
y_start = 1;   y_end = 400;


%% STEP 2: Loading & Pre-processing (grayscale, undistort, 8-bit, scale, CLAHE)
[~, bildname, ~] = fileparts(bild_pfad);

% Load original image
img = imread(bild_pfad);
if size(img,3) == 3, img = rgb2gray(img); end
img = im2uint8(img);

% >>> NEW: Undistort image using loaded cameraParams <<<
img = undistortImage(img, cameraParams);

% From here onward, the entire pipeline works with the undistorted image "img"
[hoehe, breite] = size(img);

bild_breite_mm  = Skalierungsfaktor * Abstand_cm;
pixelgroesse_mm = bild_breite_mm / breite;

img_eq  = adapthisteq(img); % CLAHE

% --- Separate PNG exports without figure/title ---
orig_out  = fullfile(export_dir, sprintf('01_Original_%s_%s.png', bildname, timestamp));
clahe_out = fullfile(export_dir, sprintf('02_CLAHE_%s_%s.png',   bildname, timestamp));
imwrite(img,    orig_out);   % here: already undistorted "original"
imwrite(img_eq, clahe_out);
fprintf('Saved: %s\n', orig_out);
fprintf('Saved: %s\n', clahe_out);


%% STEP 3: ROI MASK
maske = false(hoehe, breite);
maske(y_start:y_end, x_start:x_end) = true;

% Control 02b: mask overlay (saved)
fig2 = figure('Name','02b Mask Overlay','MenuBar','none','ToolBar','none','Color','w');
imshow(overlayMask(img_eq, maske, 0.35, [0 1 0])); axis off; mytitle('Overlay: mask on image');
save_control(fig2, fullfile(export_dir, sprintf('03_MaskenOverlay_%s_%s.png', bildname, timestamp)));

% Inner ROI (guard strip) for safe border removal
roi_margin_px = 1;
maske_inner   = imerode(maske, strel('disk',roi_margin_px));

%% STEP 4: Binarization
bw = imbinarize(img_eq,'adaptive','Sensitivity',adaptive_sensitivity);
bw(~maske_inner) = 0;
bw = bwareaopen(bw, 10);
bw = imclearborder(bw);

% Control: binary mask only as PNG
bw_out = fullfile(export_dir, sprintf('04a_BinaryMask_%s_%s.png', bildname, timestamp));
imwrite(uint8(bw)*255, bw_out);
fprintf('Saved: %s\n', bw_out);

% Control 03 binarization (overlay)
fig3b = figure('Name','03 Binarization','MenuBar','none','ToolBar','none','Color','w');
imshow(overlayMask(img_eq, bw, 0.40, [1 0 0])); axis off;
mytitle(sprintf('Adaptive Threshold (Sens=%.2f)', adaptive_sensitivity));
save_control(fig3b, fullfile(export_dir, sprintf('04b_BinarisierungOverlay_%s_%s.png', bildname, timestamp)));

%% STEP 5: Morphological opening (break contact bridges)
r_min_mm = sqrt(min_area_mm2/pi);
r_min_px = max(1, round(r_min_mm / pixelgroesse_mm));
se = strel('disk', max(1, round(0.3*r_min_px)));
bw = imopen(bw, se);

%% STEP 6: Agglomerate splitting (distance + h-minima watershed)
D  = -bwdist(~bw);
D(~bw) = -Inf;
h  = max(1, round(0.3*r_min_px));
Lw = watershed(imhmin(D, h));
bw(Lw==0) = 0;

% Control 03b splitting result
fig3c = figure('Name','03b Splitting Result','MenuBar','none','ToolBar','none','Color','w');
imshow(overlayMask(img_eq, bw, 0.35, [1 0 1])); axis off;
mytitle('After opening + h-minima watershed');
save_control(fig3c, fullfile(export_dir, sprintf('05_SplittingErgebnis_%s_%s.png', bildname, timestamp)));

%% STEP 7: Labeling & Features
labels_init = bwlabel(bw);
stats_init  = regionprops(labels_init, img_eq, ...
    'Area','Centroid','BoundingBox','MeanIntensity','PixelIdxList','Eccentricity','Perimeter');

% Control 04 pre-segmented labels
fig4 = figure('Name','04 Pre-segmented Labels','MenuBar','none','ToolBar','none','Color','w');
imshow(imoverlay(img_eq, imdilate(bwperim(labels_init>0), strel('disk',1)), [0 0 1]));
axis off; mytitle('Contours of the initial segments (blue)');
save_control(fig4, fullfile(export_dir, sprintf('06_VorsegmentierteLabels_%s_%s.png', bildname, timestamp)));

%% STEP 8: REGION FILTERING
daten = {}; pellet_count = 0;
accepted_idx = false(numel(stats_init),1);
rejected_idx = false(numel(stats_init),1);

roi_border = bwperim(maske);

for i = 1:numel(stats_init)
    A = stats_init(i).Area;
    P = max(stats_init(i).Perimeter, eps);
    rundheit = 4*pi*A/(P^2);
    if rundheit < rundheit_schwelle
        rejected_idx(i) = true; continue;
    end

    pix = double(img_eq(stats_init(i).PixelIdxList));
    std_intensity = std(pix);

    bb = stats_init(i).BoundingBox;
    x1 = bb(1); y1 = bb(2); x2 = x1 + bb(3); y2 = y1 + bb(4);
    beruehrt_rand = x1 <= 1 || y1 <= 1 || x2 >= breite || y2 >= hoehe;

    % Robust border contact against INNER ROI
    touches_roi_border = any(~maske_inner(stats_init(i).PixelIdxList));

    aspect_ratio  = max(bb(3)/bb(4), bb(4)/bb(3));
    eccentricity  = stats_init(i).Eccentricity;

    % Air bubble exclusion
    mask_region = false(size(img_eq));
    mask_region(stats_init(i).PixelIdxList) = true;
    region_mask = imfill(mask_region,'holes');
    dist_map    = bwdist(~region_mask);
    max_dist    = max(dist_map(:));
    center_mask = dist_map > 0.70*max_dist;
    edge_mask   = dist_map < 0.30*max_dist;
    center_intensity = mean(double(img_eq(center_mask)),'omitnan');
    edge_intensity   = mean(double(img_eq(edge_mask)),'omitnan');
    luftblase = edge_intensity > (center_intensity + 10);

    area_mm2 = A * (pixelgroesse_mm)^2;

    % Hard bounding-box rule against nominal ROI (with tolerance)
    tol = roi_margin_px;
    touches_roi_border_bb = (x1 <= x_start + tol) || ...
                            (y1 <= y_start + tol) || ...
                            (x2 >= x_end   - tol) || ...
                            (y2 >= y_end   - tol);

    pass = area_mm2 >= min_area_mm2 && ...
           stats_init(i).MeanIntensity <= max_mean_intensity && ...
           std_intensity <= max_std_intensity && ...
           aspect_ratio <= max_aspect_ratio && ...
           eccentricity <= max_eccentricity && ...
           ~beruehrt_rand && ...
           ~touches_roi_border && ...
           ~touches_roi_border_bb && ...
           ~luftblase;

    if pass
        pellet_count = pellet_count + 1;
        accepted_idx(i) = true;
        daten(end+1,1:8) = { [bildname,'.bmp'], pellet_count, area_mm2, ...
                             stats_init(i).MeanIntensity, std_intensity, ...
                             aspect_ratio, eccentricity, i };
    else
        rejected_idx(i) = true;
    end
end

%% STEP 9: VISUALIZATION OF FILTER RESULTS (save all)
% 05a Rejected (yellow)
fig5a = figure('Name','05a Rejected','MenuBar','none','ToolBar','none','Color','w');
imshow(img_eq); axis off; hold on;
plotLabelBoundaries(labels_init, rejected_idx & (~accepted_idx));
mytitle('Rejected – yellow'); hold off;
save_control(fig5a, fullfile(export_dir, sprintf('07_Ausgeschieden_%s_%s.png', bildname, timestamp)));

% 05b Accepted pellets (green contours + IDs)
fig5b = figure('Name','05b Accepted','MenuBar','none','ToolBar','none','Color','w');
imshow(img_eq); axis off; hold on;
accepted_labels = find(accepted_idx);
for k = 1:numel(accepted_labels)
    lab = accepted_labels(k);
    mask = labels_init == lab;
    B = bwboundaries(mask);
    if ~isempty(B)
        boundary = B{1};
        plot(boundary(:,2), boundary(:,1), 'g', 'LineWidth', 1.5);
        c = stats_init(lab).Centroid;
        text(c(1), c(2), sprintf('%d', k), 'Color','y','FontSize',10,'FontWeight','bold',...
            'HorizontalAlignment','center','VerticalAlignment','middle');
    end
end
mytitle(sprintf('Accepted: %d pellets', sum(accepted_idx))); hold off;
save_control(fig5b, fullfile(export_dir, sprintf('08_Akzeptiert_%s_%s.png', bildname, timestamp)));

% 05c Overview (red = mask, green = accepted contours)
fig5c = figure('Name','05c Overview','MenuBar','none','ToolBar','none','Color','w');
imshow(overlayMask(img_eq, bw, 0.25, [1 0 0])); axis off; hold on;
perim_mask = bwperim(ismember(labels_init, accepted_labels));
[y, x] = find(perim_mask);
plot(x, y, 'g.', 'MarkerSize', 1);
mytitle('Red: binary mask, green: accepted contours'); hold off;
save_control(fig5c, fullfile(export_dir, sprintf('09_Ueberblick_%s_%s.png', bildname, timestamp)));

%% STEP 10: Diameter & Table
if ~isempty(daten)
    durchmesser = zeros(size(daten,1),1);
    for i = 1:size(daten,1)
        area_mm2 = daten{i,3};
        durchmesser(i) = 2*sqrt(area_mm2/pi);
    end
    median_durchmesser = median(durchmesser);

    T = table( ...
        string(daten(:,1)), ...
        cell2mat(daten(:,2)), ...
        cell2mat(daten(:,3)), ...
        cell2mat(daten(:,4)), ...
        cell2mat(daten(:,5)), ...
        cell2mat(daten(:,6)), ...
        cell2mat(daten(:,7)), ...
        cell2mat(daten(:,8)), ...
        durchmesser, ...
        repmat(median_durchmesser, size(daten,1), 1), ...
        'VariableNames', {'Dateiname','PelletNr','Flaeche_mm2','Mean','Std','Aspect','Eccentricity','Label','Durchmesser_mm','MedianDurchmesser_mm'} ...
    );
else
    T = table('Size',[0 10], 'VariableTypes', ...
        {'string','double','double','double','double','double','double','double','double','double'}, ...
        'VariableNames', {'Dateiname','PelletNr','Flaeche_mm2','Mean','Std','Aspect','Eccentricity','Label','Durchmesser_mm','MedianDurchmesser_mm'});
end

disp(T);

%% STEP 11: EXPORT (Excel + clean overlay without figure UI)
excel_pfad = fullfile(export_dir, sprintf('PelletDaten_%s_%s.xlsx', bildname, timestamp));
try
    writetable(T, excel_pfad, 'FileType','spreadsheet');
    fprintf('Excel exported: %s\n', excel_pfad);
catch ME
    warning('Excel export failed: %s', ME.message);
end

% --- Clean final overlay without figure UI ---
overlay_rgb = overlayMask(img_eq, bw, 0.25, [1 0 0]);  % red = binary mask
perim_mask  = bwperim(ismember(labels_init, accepted_labels));
[yC, xC] = find(perim_mask);
for kk = 1:numel(xC)
    xi = xC(kk); yi = yC(kk);
    if xi>1 && yi>1 && xi<size(overlay_rgb,2) && yi<size(overlay_rgb,1)
        overlay_rgb(yi, xi, 1) = 0;   % R
        overlay_rgb(yi, xi, 2) = 255; % G
        overlay_rgb(yi, xi, 3) = 0;   % B
    end
end
png_path = fullfile(export_dir, sprintf('10_OverlayFinal_%s_%s.png', bildname, timestamp));
imwrite(overlay_rgb, png_path);
fprintf('Overlay saved (without figure UI): %s\n', png_path);

%% ========================================================================
%  SUPPORT FUNCTIONS
%% ========================================================================

function Iout = overlayMask(I, BW, alpha, colorRGB)
% overlayMask: apply a semi-transparent color mask on a grayscale image.
I = im2uint8(I);
if size(I,3)==1
    I = repmat(I,[1 1 3]);
end
mask = BW > 0;

overlay = uint8(zeros(size(I)));
overlay(:,:,1) = uint8(colorRGB(1) * 255);
overlay(:,:,2) = uint8(colorRGB(2) * 255);
overlay(:,:,3) = uint8(colorRGB(3) * 255);

Iout = I;
for c = 1:3
    ch = I(:,:,c);
    ov = overlay(:,:,c);
    ch(mask) = uint8( (1 - alpha) * double(ch(mask)) + alpha * double(ov(mask)) );
    Iout(:,:,c) = ch;
end
end

function plotLabelBoundaries(labels, idxLogical)
% plotLabelBoundaries: draw yellow contours for selected label IDs.
hold on;
ids = find(idxLogical);
for k = 1:numel(ids)
    lab = ids(k);
    if lab == 0, continue; end
    mask = labels == lab;
    if ~any(mask, 'all'), continue; end
    B = bwboundaries(mask);
    if ~isempty(B)
        boundary = B{1};
        plot(boundary(:,2), boundary(:,1), 'y', 'LineWidth', 1.2);
    end
end
hold off;
end

function save_control(figHandle, outPath)
% save_control: save a figure tightly without title bars.
% Requirement: axes are already set to "axis off".
set(figHandle, 'MenuBar','none','ToolBar','none','Color','w');
ax = get(figHandle,'CurrentAxes');
if ~isempty(ax)
    axis(ax, 'off');
    set(ax, 'Position',[0 0 1 1], 'Units','normalized', 'Visible','off');
end
try
    exportgraphics(figHandle, outPath, 'Resolution', 200);
    fprintf('Saved: %s\n', outPath);
catch ME
    warning('Could not save control visualization (%s): %s', outPath, ME.message);
end
drawnow;
end