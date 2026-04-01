%% ========================================================================
%  MULTI-IMAGE PELLET ANALYSIS PIPELINE
%  This script processes multiple microscopy or camera images of pellets in
%  a headless workflow. For each image, it performs lens undistortion,
%  grayscale pre-processing, adaptive contrast enhancement, ROI-based
%  segmentation, watershed-based object separation, morphological and
%  intensity-based filtering, pellet size evaluation, and export of result
%  tables and visualization PNGs.
%% ========================================================================

clc; clear; close all;

%% STEP 0: Define list of images to analyze + export directories
image_paths = {
    'C:\Path\To\Input\Images\example_image_01.bmp'
    % add more images here...
};

export_dirs = {
    'C:\Path\To\Export\Results\example_run_01'
    % add more export folders here...
};

if numel(image_paths) ~= numel(export_dirs)
    error('Number of image paths (%d) does not match number of export directories (%d).', ...
        numel(image_paths), numel(export_dirs));
end

% --- Load camera parameters only once ---
S = load('C:\Path\To\Calibration\camera_calibration_parameters.mat');
cameraParams = S.cameraParams;
fprintf('[INFO] cameraParams loaded.\n');

%% Shared analysis parameters (same for all images)
distance_cm         = 178;
scaling_factor      = 5.02 / 12;

min_area_mm2        = 0.5;   % minimum pellet area [mm^2]
max_mean_intensity  = 160;   % maximum mean intensity of a pellet [0–255]
max_std_intensity   = 30;    % maximum within-pellet intensity std
max_aspect_ratio    = 2;     % bounding box long/short side < 2
max_eccentricity    = 0.95;  % ellipse-like elongation 0 (circle) – 1 (line)
circularity_thresh  = 0.5;   % 4*pi*A/P^2 circularity
adaptive_sensitivity = 0.56; % adaptive threshold sensitivity [0–1]

% Regional mask (nominal ROI coordinates)
x_start = 126; x_end = 1330; % ROI in X
y_start = 1;   y_end = 400;  % ROI in Y

%% STEP 1: Loop over all images
for idx = 1:numel(image_paths)
    image_path = image_paths{idx};
    export_dir = export_dirs{idx};

    fprintf('\n[%02d/%02d] Analyzing image:\n  %s\n  -> Export: %s\n', ...
        idx, numel(image_paths), image_path, export_dir);

    if ~exist(export_dir, 'dir')
        mkdir(export_dir);
    end

    try
        analyzeSingleImage(image_path, export_dir, cameraParams, ...
            distance_cm, scaling_factor, ...
            min_area_mm2, max_mean_intensity, max_std_intensity, ...
            max_aspect_ratio, max_eccentricity, circularity_thresh, ...
            adaptive_sensitivity, x_start, x_end, y_start, y_end);
    catch ME
        warning('Error for image %s: %s', image_path, ME.message);
    end
end

fprintf('\n[INFO] Done. All images processed.\n');


%% ========================================================================
%  LOCAL FUNCTIONS
%% ========================================================================

function analyzeSingleImage(image_path, export_dir, cameraParams, ...
    distance_cm, scaling_factor, ...
    min_area_mm2, max_mean_intensity, max_std_intensity, ...
    max_aspect_ratio, max_eccentricity, circularity_thresh, ...
    adaptive_sensitivity, x_start, x_end, y_start, y_end)

    %% Create timestamp once per image (so Excel + all PNGs match)
    timestamp = datestr(now,'yyyymmdd_HHMMSS');

    %% Container for all figures (still exported as figure-based PNGs)
    figs     = gobjects(0);
    fig_names = {};

    %% STEP 2: Loading & pre-processing (grayscale, undistort, exclude zero-border, CLAHE)
    [~, image_name, ext] = fileparts(image_path); % base file name for export
    img = imread(image_path);                     % load image
    if size(img,3) == 3, img = rgb2gray(img); end
    img = im2uint8(img);                         % ensure 8-bit

    % --- Undistortion ---
    img = undistortImage(img, cameraParams);

    [height, width] = size(img);                 % size of the undistorted image

    % Mask of valid pixels (everything except artificial black border)
    valid_mask = img > 0;

    % Separate copies:
    img_forStd    = img; % for std / bubble detection (without CLAHE)
    img_forThresh = img; % for thresholding / CLAHE

    % Neutralize black border pixels for thresholding
    if any(valid_mask, 'all')
        bg_val = median(double(img(valid_mask)), 'omitnan'); % typical background
    else
        bg_val = 0; % fallback
    end
    img_forThresh(~valid_mask) = uint8(bg_val);

    % Physical scaling
    image_width_mm = scaling_factor * distance_cm; % scene width in mm
    pixel_size_mm  = image_width_mm / double(width); % mm per pixel

    % CLAHE on the "cleaned" image
    img_eq = adapthisteq(img_forThresh);

    % ---------------------------------------------------------------------
    % NEW: Do NOT save "01 Load & Pre-processing" as a tiled figure,
    %      but as 3 individual PNGs directly from arrays.
    % ---------------------------------------------------------------------
    try
        imwrite(img, fullfile(export_dir, sprintf('01a_Undistorted_Original_%s_%s.png', image_name, timestamp)));
        imwrite(img_eq, fullfile(export_dir, sprintf('01b_CLAHE_%s_%s.png', image_name, timestamp)));
        imwrite(uint8(valid_mask)*255, fullfile(export_dir, sprintf('01c_ValidMask_%s_%s.png', image_name, timestamp)));
        fprintf('  [OK] Preview PNGs (01a/01b/01c) saved.\n');
    catch ME
        warning('Preview PNG export failed: %s', ME.message);
    end

    %% STEP 3: ROI MASK (restrict analysis to ROI; exclude frame/holder)
    roi_mask = false(height, width);
    roi_mask(y_start:y_end, x_start:x_end) = true;

    % Intersect ROI directly with valid_mask
    roi_mask = roi_mask & valid_mask;

    fig = figure('Name','02b Mask Overlay','Visible','off');
    imshow(overlayMask(img_eq, roi_mask, 0.35, [0 1 0]));
    title('Overlay: mask (ROI ∩ valid\_mask) on image');
    figs(end+1) = fig; %#ok<AGROW>
    fig_names{end+1} = '02b_Mask_Overlay';

    % Define "inner" ROI (guard strip)
    roi_margin_px = 1; % edge distance in pixels
    roi_mask_inner = imerode(roi_mask, strel('disk', roi_margin_px));
    roi_mask_inner = roi_mask_inner & valid_mask; % explicitly restrict to valid pixels

    %% STEP 4: Binarization (adaptive thresholding + cleanup of specks/borders)
    bw = imbinarize(img_eq, 'adaptive', 'Sensitivity', adaptive_sensitivity);

    % Remove invalid regions using masks
    bw(~valid_mask)     = 0; % no segments on artificial black border
    bw(~roi_mask_inner) = 0; % work only inside the inner ROI

    bw = bwareaopen(bw, 10); % remove very small segments
    bw = imclearborder(bw);  % remove image-border-touching objects

    fig = figure('Name','03a Binarization BW','Visible','off');
    imshow(bw); title('Binary mask after adaptive threshold');
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '03a_Binarization_BW';

    fig = figure('Name','03b Binarization Overlay','Visible','off');
    imshow(overlayMask(img_eq, bw, 0.40, [1 0 0]));
    title(sprintf('Adaptive threshold (Sens=%.2f)', adaptive_sensitivity));
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '03b_Binarization_Overlay';

    %% STEP 5: Minimum radius + opening
    r_min_mm = sqrt(min_area_mm2 / pi);
    r_min_px = max(1, round(r_min_mm / pixel_size_mm));
    se = strel('disk', max(1, round(0.3 * r_min_px)));
    bw = imopen(bw, se);

    %% STEP 6: Splitting (distance transform + h-minima watershed)
    D = -bwdist(~bw);
    D(~bw) = -Inf;
    h = max(1, round(0.3 * r_min_px));
    Lw = watershed(imhmin(D, h));
    bw(Lw == 0) = 0;

    fig = figure('Name','04 Splitting Result','Visible','off');
    imshow(overlayMask(img_eq, bw, 0.35, [1 0 1]));
    title('After opening + h-minima watershed');
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '04_Splitting';

    %% STEP 7: Labeling & features
    labels_init = bwlabel(bw);
    stats_init = regionprops(labels_init, img_eq, ...
        'Area','Centroid','BoundingBox','MeanIntensity','PixelIdxList','Eccentricity','Perimeter');

    fig = figure('Name','05 Pre-segmented Labels','Visible','off');
    imshow(imoverlay(img_eq, imdilate(bwperim(labels_init > 0), strel('disk',1)), [0 0 1]));
    title('Contours of initial segments (blue)');
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '05_Presegmented_Labels';

    %% STEP 8: REGION FILTERING
    data = {}; 
    pellet_count = 0;
    accepted_idx = false(numel(stats_init),1);
    rejected_idx = false(numel(stats_init),1);

    for i = 1:numel(stats_init)
        % Basic geometry
        A = stats_init(i).Area;
        P = max(stats_init(i).Perimeter, eps);
        circularity = 4 * pi * A / (P^2);
        if circularity < circularity_thresh
            rejected_idx(i) = true;
            continue;
        end

        % Intensity std on img_forStd (without CLAHE)
        pix = double(img_forStd(stats_init(i).PixelIdxList));
        std_intensity = std(pix);

        bb = stats_init(i).BoundingBox; % [x y w h]
        x1 = bb(1); y1 = bb(2); x2 = x1 + bb(3); y2 = y1 + bb(4);
        touches_image_border = x1 <= 1 || y1 <= 1 || x2 >= width || y2 >= height;

        % Border-contact checks
        touches_roi_border = any(~roi_mask_inner(stats_init(i).PixelIdxList));
        aspect_ratio = max(bb(3)/bb(4), bb(4)/bb(3));
        eccentricity = stats_init(i).Eccentricity;

        % Air bubble exclusion (bright rim) on img_forStd
        mask_region = false(size(img_eq));
        mask_region(stats_init(i).PixelIdxList) = true;
        region_mask = imfill(mask_region, 'holes');
        dist_map    = bwdist(~region_mask);
        max_dist    = max(dist_map(:));
        center_mask = dist_map > 0.70 * max_dist;
        edge_mask   = dist_map < 0.30 * max_dist;

        center_intensity = mean(double(img_forStd(center_mask)), 'omitnan');
        edge_intensity   = mean(double(img_forStd(edge_mask)), 'omitnan');
        air_bubble       = edge_intensity > (center_intensity + 10);

        area_mm2 = A * (pixel_size_mm)^2;

        % Bounding box against nominal ROI with tolerance
        tol = roi_margin_px;
        touches_roi_border_bb = (x1 <= x_start + tol) || (y1 <= y_start + tol) || ...
                                (x2 >= x_end   - tol) || (y2 >= y_end   - tol);

        % Acceptance rules
        pass = area_mm2 >= min_area_mm2 && ...
               stats_init(i).MeanIntensity <= max_mean_intensity && ...
               std_intensity <= max_std_intensity && ...
               aspect_ratio <= max_aspect_ratio && ...
               eccentricity <= max_eccentricity && ...
               ~touches_image_border && ...
               ~touches_roi_border && ...
               ~touches_roi_border_bb && ...
               ~air_bubble;

        if pass
            pellet_count = pellet_count + 1;
            accepted_idx(i) = true;
            data(end+1,1:8) = { [image_name, ext], pellet_count, area_mm2, ...
                                stats_init(i).MeanIntensity, std_intensity, ...
                                aspect_ratio, eccentricity, i };
        else
            rejected_idx(i) = true;
        end
    end

    %% STEP 9: VISUALIZATION OF FILTER RESULTS
    fig = figure('Name','06a Rejected','Visible','off');
    imshow(img_eq); hold on;
    plotLabelBoundaries(labels_init, rejected_idx & (~accepted_idx));
    title('Rejected – yellow');
    hold off;
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '06a_Rejected';

    fig = figure('Name','06b Accepted Pellets','Visible','off');
    imshow(img_eq); hold on;
    accepted_labels = find(accepted_idx);
    for k = 1:numel(accepted_labels)
        lab = accepted_labels(k);
        mask = labels_init == lab;
        B = bwboundaries(mask);
        if ~isempty(B)
            boundary = B{1};
            plot(boundary(:,2), boundary(:,1), 'g', 'LineWidth', 1.5);
            c = stats_init(lab).Centroid;
            text(c(1), c(2), sprintf('%d', k), 'Color','y','FontSize',10,'FontWeight','bold', ...
                'HorizontalAlignment','center','VerticalAlignment','middle');
        end
    end
    title(sprintf('Accepted: %d pellets', sum(accepted_idx)));
    hold off;
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '06b_Accepted_Pellets';

    fig = figure('Name','06c Overview','Visible','off');
    imshow(overlayMask(img_eq, bw, 0.25, [1 0 0])); hold on;
    perim_mask = bwperim(ismember(labels_init, accepted_labels));
    [yy, xx] = find(perim_mask);
    plot(xx, yy, 'g.', 'MarkerSize', 1);
    title('Red: binary mask, green: accepted contours');
    hold off;
    figs(end+1) = fig; %#ok<SAGROW>
    fig_names{end+1} = '06c_Overview_Overlay';

    %% STEP 10: Diameter & tables (per pellet + Q1/median/Q3)
    if ~isempty(data)
        nPellets   = size(data,1);
        diameters  = zeros(nPellets,1);
        areas      = zeros(nPellets,1);

        for ii = 1:nPellets
            area_mm2_i   = data{ii,3};
            areas(ii)    = area_mm2_i;
            diameters(ii) = 2 * sqrt(area_mm2_i / pi);
        end

        % Quartiles for diameter
        q_d  = prctile(diameters, [25 50 75]);
        q1_d = q_d(1); med_d = q_d(2); q3_d = q_d(3);

        % Quartiles for area
        q_a  = prctile(areas, [25 50 75]);
        q1_a = q_a(1); med_a = q_a(2); q3_a = q_a(3);

        % Per-pellet table
        T = table( ...
            string(data(:,1)), ...
            cell2mat(data(:,2)), ...
            cell2mat(data(:,3)), ...
            cell2mat(data(:,4)), ...
            cell2mat(data(:,5)), ...
            cell2mat(data(:,6)), ...
            cell2mat(data(:,7)), ...
            cell2mat(data(:,8)), ...
            diameters, ...
            repmat(med_d, nPellets, 1), ...
            'VariableNames', {'Filename','PelletNo','Area_mm2','Mean','Std','Aspect','Eccentricity','Label','Diameter_mm','MedianDiameter_mm'} ...
        );

        % Summary
        Summary = table( ...
            string(image_name), ...
            1, ...
            nPellets, ...
            q1_d, med_d, q3_d, ...
            med_d - q1_d, ...
            q3_d - med_d, ...
            med_a, ...
            med_a - q1_a, ...
            q3_a - med_a, ...
            'VariableNames', {'Image','Number_of_Images','Total_Pellets', ...
                              'Q1_mm','Median_mm','Q3_mm','Median_minus_Q1','Q3_minus_Median', ...
                              'MedianArea_mm2','MedianArea_minus_Q1','Q3_minus_MedianArea'} ...
        );
    else
        T = table('Size',[0 10], 'VariableTypes', ...
            {'string','double','double','double','double','double','double','double','double','double'}, ...
            'VariableNames', {'Filename','PelletNo','Area_mm2','Mean','Std','Aspect','Eccentricity','Label','Diameter_mm','MedianDiameter_mm'});

        Summary = table( ...
            string(image_name), ...
            1, ...
            0, ...
            NaN, NaN, NaN, NaN, NaN, ...
            NaN, NaN, NaN, ...
            'VariableNames', {'Image','Number_of_Images','Total_Pellets', ...
                              'Q1_mm','Median_mm','Q3_mm','Median_minus_Q1','Q3_minus_Median', ...
                              'MedianArea_mm2','MedianArea_minus_Q1','Q3_minus_MedianArea'} ...
        );
    end

    %% STEP 11: EXPORT (Excel table + all figure PNGs)
    excel_path = fullfile(export_dir, sprintf('PelletData_%s_%s.xlsx', image_name, timestamp));

    try
        writetable(T,       excel_path, 'FileType','spreadsheet', 'Sheet','RawData');
        writetable(Summary, excel_path, 'FileType','spreadsheet', 'Sheet','Summary');
        fprintf('  [OK] Excel exported: %s\n', excel_path);
    catch ME
        warning('Excel export failed (%s): %s', excel_path, ME.message);
    end

    % Save and close all figures
    for iFig = 1:numel(figs)
        if ~isvalid(figs(iFig)), continue; end
        png_path = fullfile(export_dir, sprintf('%s_%s_%s.png', ...
            fig_names{iFig}, image_name, timestamp));
        try
            exportgraphics(figs(iFig), png_path, 'Resolution', 200);
            fprintf('  [OK] Figure saved: %s\n', png_path);
        catch ME
            warning('Saving figure %s failed: %s', fig_names{iFig}, ME.message);
        end
        close(figs(iFig));
    end
end


%% ===== SUPPORT: overlayMask =============================================
function Iout = overlayMask(I, BW, alpha, colorRGB)
    I = im2uint8(I);
    if size(I,3) == 1
        I = repmat(I, [1 1 3]);
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
        ch(mask) = uint8((1 - alpha) * double(ch(mask)) + alpha * double(ov(mask)));
        Iout(:,:,c) = ch;
    end
end

%% ===== SUPPORT: plotLabelBoundaries =====================================
function plotLabelBoundaries(labels, idxLogical)
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