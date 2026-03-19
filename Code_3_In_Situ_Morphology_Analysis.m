%% Recursive, leaf-wise pellet analysis (v3a: continuously updated master file, no leaf Excels)
%
% Function:
%   This script recursively scans a root directory for image-containing leaf folders
%   and performs automated pellet analysis on all valid images found therein.
%   Each image is undistorted using precomputed camera calibration parameters,
%   segmented, and filtered based on geometric and intensity-based criteria.
%   Results are aggregated across images and folders and written continuously
%   into a master Excel file.
%
% Inputs:
%   - bild_wurzel: root directory containing the image folders to be analyzed
%   - export_dir: directory used for log files and auxiliary exports
%   - cameraParams: MATLAB camera calibration parameters for image undistortion
%   - allowed_ext: allowed image file extensions for recursive image search
%   - Analysis parameters:
%       Abstand_cm, Skalierungsfaktor,
%       min_area_mm2, max_mean_intensity, max_std_intensity,
%       max_aspect_ratio, max_eccentricity, rundheit_schwelle,
%       adaptive_sensitivity
%   - ROI definition:
%       x_start, x_end, y_start, y_end
%   - Logging / progress settings:
%       print_progress, log_to_file
%
% Outputs:
%   - Master Excel file with the sheets:
%       Folder_Median   -> aggregated pellet statistics per leaf folder
%       PerBild_Stats   -> pellet count statistics per image / folder
%       Rohdaten        -> raw per-pellet diameter data
%   - Optional per-folder log files (if log_to_file = true)
%   - Console progress output during execution

%% Step 1: Setup
clc; clear; close all;                                   % clean start

% Root and export folders
bild_wurzel = 'PATH_TO_ROOT_IMAGE_FOLDER';
export_dir  = 'PATH_TO_EXPORT_FOLDER';
if ~exist(export_dir, 'dir'), mkdir(export_dir); end      % create export folder if missing

% Allowed image extensions (case-insensitive). Add/remove here if needed:
allowed_ext = lower(string({'.bmp','.png','.jpg','.jpeg','.tif','.tiff'}));

% Progress and logging controls
print_progress = true;                                    % show progress in Command Window
log_to_file    = true;                                    % also write a log file per leaf folder
log_root       = fullfile(export_dir, '_logs');           % folder for logs
if log_to_file && ~exist(log_root, 'dir'), mkdir(log_root); end

% >>> NEW: load camera parameters for undistortion <<<
S = load('PATH_TO_CAMERA_PARAMS_FILE\cameraParams_Bildentzerrung.mat', ...
         'cameraParams');
cameraParams = S.cameraParams;
if print_progress
    fprintf('[%s] cameraParams loaded.\n', nowstr());
end

% Analysis parameters (same as single-image pipeline)
Abstand_cm        = 178;             % measured distance from camera to reactor inside
Skalierungsfaktor = 5.02 / 12;

min_area_mm2        = 0.5;
max_mean_intensity  = 160;
max_std_intensity   = 60;
max_aspect_ratio    = 2;
max_eccentricity    = 0.95;
rundheit_schwelle   = 0.5;           % 4*pi*A/P^2

adaptive_sensitivity = 0.56;         % sensitivity for adaptive thresholding

% Regional mask (clipped per image to valid bounds)
x_start = 126; x_end = 1330;
y_start = 1;   y_end = 400;

%% Step 1.1: Master accumulators (for the Master Excel)
Master_FolderMedian = table('Size',[0 12], 'VariableTypes', ...
    {'string','string','double','double','double','double','double','double','double','double','double','double'}, ...
    'VariableNames', {'RelOrdner','LeafName','Anzahl_Bilder','Pellets_gesamt', ...
                      'Q1_mm','Median_mm','Q3_mm','Median_minus_Q1','Q3_minus_Median', ...
                      'MedianArea_mm2','MedianArea_minus_Q1','Q3_minus_MedianArea'});

Master_PerBildStats = table('Size',[0 5], 'VariableTypes', ...
    {'string','string','double','double','double'}, ...
    'VariableNames', {'RelOrdner','LeafName','MeanPelletsProBild','StdPelletsProBild','Anzahl_Bilder'});

Master_Rohdaten = table('Size',[0 4], 'VariableTypes', ...
    {'string','string','string','double'}, ...
    'VariableNames', {'RelOrdner','LeafName','Bild','Durchmesser_mm'});

% >>> NEW: define the master file directly at the beginning and create it once initially <<<
master_timestamp = datestr(now,'yyyymmdd_HHMMSS');
master_xlsx = fullfile(bild_wurzel, sprintf('Master_entzerrt_ohnedunklenRand_%s.xlsx', master_timestamp));

try
    writetable(Master_FolderMedian, master_xlsx, 'FileType','spreadsheet', 'Sheet','Folder_Median');
    writetable(Master_PerBildStats, master_xlsx, 'FileType','spreadsheet', 'Sheet','PerBild_Stats');
    writetable(Master_Rohdaten,    master_xlsx, 'FileType','spreadsheet', 'Sheet','Rohdaten');
    if print_progress
        fprintf('[%s] Empty master file created: %s\n', nowstr(), master_xlsx);
    end
catch ME
    warning('Initial creation of the master file failed (%s): %s', master_xlsx, ME.message);
end

%% Step 2: Find leaf folders (contain images themselves, but no deeper image subfolders)
% Robust recursive listing of all image files under bild_wurzel:
alle_files = listImagesRecursive(bild_wurzel, allowed_ext);
if isempty(alle_files)
    error('No matching image files found under "%s".', bild_wurzel);
end

% Build list of unique folders containing at least one matching file
alle_dirs = unique(string({alle_files.folder}))';

% Mark which of these are "leaf" folders: none of their subfolders also contains images
isLeaf = true(size(alle_dirs));
for i = 1:numel(alle_dirs)
    prefix = alle_dirs(i) + filesep;
    for j = 1:numel(alle_dirs)
        if i~=j && startsWith(alle_dirs(j), prefix, 'IgnoreCase', true)
            isLeaf(i) = false;
            break;
        end
    end
end
leaf_dirs = alle_dirs(isLeaf);
if print_progress
    fprintf('[%s] Leaf folders found: %d\n', nowstr(), numel(leaf_dirs));
end

%% Step 3: Process each leaf folder
for k = 1:numel(leaf_dirs)
    ordner = char(leaf_dirs(k));
    if print_progress
        fprintf('\n[%s] Start folder (%d/%d)\n%s\n', nowstr(), k, numel(leaf_dirs), ordner);
    end
    try
        % ---- Call per-folder processor (returns tables for master aggregation) ----
        [T_all, PerBild, Summary, rel, leaf_name] = processLeaf(ordner, bild_wurzel, export_dir, cameraParams, ...
            Abstand_cm, Skalierungsfaktor, ...
            min_area_mm2, max_mean_intensity, max_std_intensity, max_aspect_ratio, max_eccentricity, rundheit_schwelle, ...
            adaptive_sensitivity, x_start, x_end, y_start, y_end, allowed_ext, ...
            print_progress, log_to_file, log_root);

        % ---- Aggregate into master tables ----
        % 3.A: Folder_Median: Q1/Median/Q3 over all pellet diameters of the leaf folder
        if ~isempty(T_all)
            diam = T_all.Durchmesser_mm;
            area = T_all.Flaeche_mm2;

            % Diameter quartiles
            q_d  = prctile(diam,[25 50 75]);
            q1_d = q_d(1); med_d = q_d(2); q3_d = q_d(3);

            % Area quartiles
            q_a  = prctile(area,[25 50 75]);
            q1_a = q_a(1); med_a = q_a(2); q3_a = q_a(3);

            Master_FolderMedian(end+1,:) = { ...
                string(rel), string(leaf_name), ...
                Summary.Anzahl_Bilder, height(T_all), ...
                q1_d, med_d, q3_d, med_d - q1_d, q3_d - med_d, ...
                med_a, med_a - q1_a, q3_a - med_a };
        else
            Master_FolderMedian(end+1,:) = { ...
                string(rel), string(leaf_name), ...
                Summary.Anzahl_Bilder, 0, ...
                NaN, NaN, NaN, NaN, NaN, ...
                NaN, NaN, NaN };
        end

        % 3.B: PerBild_Stats: mean & sample std of pellets per image (ignoring NaNs)
        val_counts = PerBild.Pellets_im_Bild(~isnan(PerBild.Pellets_im_Bild));
        mean_pb = mean(val_counts,'omitnan');
        std_pb  = std(val_counts,'omitnan');   % sample std (n-1) by default
        Master_PerBildStats(end+1,:) = { string(rel), string(leaf_name), mean_pb, std_pb, numel(val_counts) };

        % 3.C: Rohdaten: per-pellet rows with folder + image context
        if ~isempty(T_all)
            Master_Rohdaten = [Master_Rohdaten; ...
                table(repmat(string(rel),height(T_all),1), repmat(string(leaf_name),height(T_all),1), ...
                      string(T_all.Dateiname), T_all.Durchmesser_mm, ...
                      'VariableNames', Master_Rohdaten.Properties.VariableNames) ...
            ]; %#ok<AGROW>
        end

        % >>> NEW: update the master Excel after each leaf folder <<<
        try
            writetable(Master_FolderMedian, master_xlsx, 'FileType','spreadsheet', 'Sheet','Folder_Median');
            writetable(Master_PerBildStats, master_xlsx, 'FileType','spreadsheet', 'Sheet','PerBild_Stats');
            writetable(Master_Rohdaten,    master_xlsx, 'FileType','spreadsheet', 'Sheet','Rohdaten');

            if print_progress
                fprintf('  [%s] Master Excel updated: %s\n', nowstr(), master_xlsx);
            end
        catch ME
            warning('Updating the master Excel failed (%s): %s', master_xlsx, ME.message);
        end

        % free memory but keep state and masters
        clearvars -except bild_wurzel export_dir ...
            Abstand_cm Skalierungsfaktor ...
            min_area_mm2 max_mean_intensity max_std_intensity max_aspect_ratio max_eccentricity rundheit_schwelle ...
            adaptive_sensitivity x_start x_end y_start y_end allowed_ext alle_files alle_dirs isLeaf leaf_dirs k ...
            print_progress log_to_file log_root ...
            Master_FolderMedian Master_PerBildStats Master_Rohdaten cameraParams ...
            master_xlsx master_timestamp
    catch ME
        warning('Error in folder %s: %s', ordner, ME.message);
    end
end

if print_progress
    fprintf('\n[%s] Done. All leaf folders processed.\n', nowstr());
    fprintf('[%s] Final master Excel is located at: %s\n', nowstr(), master_xlsx);
end

% --- IMPORTANT: Step 4 (writing the master Excel once at the end) has been removed,
%     because the file is already written inside the loop after each leaf folder. ---


%% ============================= SUPPORT FUNCTION =============================
% Returns the three tables used to build the master file, plus rel path and leaf name.
function [T_all, PerBild, Summary, rel, leaf_name] = processLeaf(bild_ordner, wurzel, export_base, cameraParams, ...
    Abstand_cm, Skalierungsfaktor, ...
    min_area_mm2, max_mean_intensity, max_std_intensity, max_aspect_ratio, max_eccentricity, rundheit_schwelle, ...
    adaptive_sensitivity, x_start, x_end, y_start, y_end, allowed_ext, ...
    print_progress, log_to_file, log_root)

    %% P3.1: Robustly enumerate images directly in this leaf (no subfolders)
    [dateien, skipped] = listImagesHere(bild_ordner, allowed_ext); % struct array, non-recursive
    if isempty(dateien)
        if print_progress
            fprintf('  [%s] Skipped (no images directly in %s)\n', nowstr(), bild_ordner);
        end
        % prepare outputs
        rel = relPath(bild_ordner, wurzel);
        [~, leaf_name] = fileparts(bild_ordner);
        T_all = table('Size',[0 10], 'VariableTypes', ...
            {'string','double','double','double','double','double','double','double','double','double'}, ...
            'VariableNames', {'Dateiname','PelletNr','Flaeche_mm2','Mean','Std','Aspect','Eccentricity','Label','Durchmesser_mm','MedianDurchmesser_mm'});
        PerBild = table('Size',[0 2], 'VariableTypes', {'string','double'}, 'VariableNames', {'Bild','Pellets_im_Bild'});
        Summary = table(string(bild_ordner), 0, 0, NaN, NaN, 'VariableNames', {'Ordner','Anzahl_Bilder','Pellets_gesamt','Durchschnitt_Pellets_pro_Bild','Median_Pellets_pro_Bild'});
        return;
    end

    rel     = relPath(bild_ordner, wurzel);
    [~, leaf_name] = fileparts(bild_ordner);

    %% P3.3: Optional per-folder logging
    if log_to_file
        rel_safe = regexprep(rel,'[\\/]+','_');
        timestamp  = datestr(now,'yyyymmdd_HHMMSS');
        log_file = fullfile(log_root, sprintf('log_%s_%s.txt', rel_safe, timestamp));
        diary(log_file); diary on;
        fprintf('[%s] LOG started: %s\n', nowstr(), log_file);
    end

    if print_progress
        fprintf('  [%s] Subpath: %s\n', nowstr(), rel);
        fprintf('  [%s] Images in folder: %d (skipped: %d)\n', nowstr(), numel(dateien), skipped);
    end

    %% P3.4: Initialize per-folder containers
    T_all = table('Size',[0 10], 'VariableTypes', ...
        {'string','double','double','double','double','double','double','double','double','double'}, ...
        'VariableNames', {'Dateiname','PelletNr','Flaeche_mm2','Mean','Std','Aspect','Eccentricity','Label','Durchmesser_mm','MedianDurchmesser_mm'});

    pellets_pro_bild = zeros(numel(dateien),1);
    bildliste        = strings(numel(dateien),1);

    %% P3.5: Loop over all images in this leaf
    for idx = 1:numel(dateien)
        % bookkeeping
        bild_pfad = fullfile(dateien(idx).folder, dateien(idx).name);
        [~, bildname, ext] = fileparts(bild_pfad);
        bildliste(idx) = string([bildname ext]);

        if print_progress
            fprintf('    [%s] Analyzing (%d/%d): %s ... ', nowstr(), idx, numel(dateien), [bildname ext]);
        end

        try
            % --- Read & standardize ---
            img = imread(bild_pfad);
            if size(img,3) == 3, img = rgb2gray(img); end
            img = im2uint8(img);

            % >>> Undistortion with cameraParams <<<
            img = undistortImage(img, cameraParams);
            [hoehe, breite] = size(img);

            % >>> NEW: valid pixel mask (everything that is not artificial black border)
            valid_mask = img > 0;

            % Copy for intensity metrics (Std, bubble) on the undistorted original
            img_forStd = img;

            % --- Scale ---
            bild_breite_mm   = Skalierungsfaktor * Abstand_cm;
            pixelgroesse_mm  = bild_breite_mm / double(breite);

            % --- Neutralize black border pixels for thresholding ---
            if any(valid_mask,'all')
                bg_val = median(double(img(valid_mask)),'omitnan');  % typical background
            else
                bg_val = 0;
            end
            img_forThresh = img;
            img_forThresh(~valid_mask) = uint8(bg_val);

            % --- CLAHE (for segmentation) ---
            img_eq       = adapthisteq(img_forThresh);
            img_smoothed = img_eq;

            % --- ROI (inner) ---
            xs = max(1, min([x_start, x_end, breite]));
            xe = min(breite, max([x_start, x_end, 1]));
            ys = max(1, min([y_start, y_end, hoehe]));
            ye = min(hoehe,  max([y_start, y_end, 1]));
            if xs > xe, tmp=xs; xs=xe; xe=tmp; end
            if ys > ye, tmp=ys; ys=ye; ye=tmp; end
            maske = false(hoehe, breite);
            maske(ys:ye, xs:xe) = true;
            roi_margin_px = 1;
            maske_inner   = imerode(maske, strel('disk',roi_margin_px));

            % NEW: additionally restrict inner ROI to valid pixels
            maske_inner = maske_inner & valid_mask;

            % --- Threshold & cleanup ---
            bw = imbinarize(img_smoothed,'adaptive','Sensitivity',adaptive_sensitivity);
            bw(~maske_inner) = 0;
            bw = bwareaopen(bw, 10);
            bw = imclearborder(bw);

            % Safety: definitely remove black border
            bw(~valid_mask) = 0;

            % --- Split (opening + watershed) ---
            r_min_mm = sqrt(min_area_mm2/pi);
            r_min_px = max(1, round(r_min_mm / pixelgroesse_mm));
            se = strel('disk', max(1, round(0.3*r_min_px)));
            bw = imopen(bw, se);

            D  = -bwdist(~bw);
            D(~bw) = -Inf;
            h  = max(1, round(0.3*r_min_px));
            Lw = watershed(imhmin(D, h));
            bw(Lw==0) = 0;

            % --- Features ---
            labels_init = bwlabel(bw);
            stats_init  = regionprops(labels_init, img_smoothed, ...
                'Area','Centroid','BoundingBox','MeanIntensity','PixelIdxList','Eccentricity','Perimeter');

            daten = {};
            pellet_count = 0;

            for i = 1:numel(stats_init)
                % Roundness pre-filter
                A = stats_init(i).Area;
                P = max(stats_init(i).Perimeter, eps);
                rundheit = 4*pi*A/(P^2);
                if rundheit < rundheit_schwelle
                    continue;
                end

                % Intensity variation (on the undistorted image without CLAHE, only within the pellet)
                pix = double(img_forStd(stats_init(i).PixelIdxList));
                std_intensity = std(pix);

                % Border contact
                bb = stats_init(i).BoundingBox; % [x y w h]
                x1 = bb(1); y1 = bb(2); x2 = x1 + bb(3); y2 = y1 + bb(4);
                beruehrt_rand = x1 <= 1 || y1 <= 1 || x2 >= breite || y2 >= hoehe;
                tol = roi_margin_px;
                touches_roi_border = any(~maske_inner(stats_init(i).PixelIdxList));
                touches_roi_border_bb = (x1 <= xs + tol) || (y1 <= ys + tol) || (x2 >= xe - tol) || (y2 >= ye - tol);

                % Shape
                aspect_ratio  = max(bb(3)/bb(4), bb(4)/bb(3));
                eccentricity  = stats_init(i).Eccentricity;

                % Bubble check (bright rim) on img_forStd
                mask_region = false(size(img_smoothed));
                mask_region(stats_init(i).PixelIdxList) = true;
                region_mask = imfill(mask_region,'holes');
                dist_map    = bwdist(~region_mask);
                max_dist    = max(dist_map(:));
                center_mask = dist_map > 0.70*max_dist;
                edge_mask   = dist_map < 0.30*max_dist;
                center_intensity = mean(double(img_forStd(center_mask)),'omitnan');
                edge_intensity   = mean(double(img_forStd(edge_mask)),'omitnan');
                luftblase        = edge_intensity > (center_intensity + 10);

                % Metric conversion & acceptance
                area_mm2 = A * (pixelgroesse_mm)^2;
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
                    daten(end+1,1:8) = { [bildname, ext], pellet_count, area_mm2, ...
                                         stats_init(i).MeanIntensity, std_intensity, ...
                                         aspect_ratio, eccentricity, i };
                end
            end

            % per-image summary & append to T_all
            pellets_pro_bild(idx) = pellet_count;
            if ~isempty(daten)
                durchmesser = zeros(size(daten,1),1);
                for ii = 1:size(daten,1)
                    area_i = daten{ii,3};
                    durchmesser(ii) = 2*sqrt(area_i/pi);
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

                if idx==1
                    T_all = T;
                else
                    T_all = [T_all; T]; %#ok<AGROW>
                end
            end

            if print_progress
                fprintf('Pellets: %d\n', pellet_count);
            end

        catch ME
            if print_progress, fprintf('ERROR\n'); end
            warning('Error for image %s: %s', [bildname ext], ME.message);
            pellets_pro_bild(idx) = NaN;
        end
    end

    % Folder-level stats & tables
    val_counts     = pellets_pro_bild(~isnan(pellets_pro_bild));
    bilder_anzahl  = numel(val_counts);
    pellets_gesamt = sum(val_counts);
    avg_per_image  = mean(val_counts);
    med_per_image  = median(val_counts);

    Summary = table( ...
        string(bild_ordner), bilder_anzahl, pellets_gesamt, avg_per_image, med_per_image, ...
        'VariableNames', {'Ordner','Anzahl_Bilder','Pellets_gesamt','Durchschnitt_Pellets_pro_Bild','Median_Pellets_pro_Bild'});

    PerBild = table(string(bildliste), pellets_pro_bild, 'VariableNames', {'Bild','Pellets_im_Bild'});

    % >>> OLD: per-leaf Excel used to be written here. This is now REMOVED. <<<

    if log_to_file
        fprintf('[%s] LOG end.\n', nowstr());
        diary off;
    end
end

%% ===== Helper: list images non-recursively in a given folder (robust) =====
function [files, skipped] = listImagesHere(folder, allowed_ext)
    d = dir(folder);
    % keep only files (no dirs)
    d = d(~[d.isdir]);
    skipped = 0;
    keep = false(size(d));
    for i = 1:numel(d)
        [~,~,e] = fileparts(d(i).name);
        if any(strcmpi(string(e), allowed_ext))
            keep(i) = true;
        else
            skipped = skipped + 1;
        end
    end
    files = d(keep);
    % natural-like sort by name
    [~,ix] = sort(lower({files.name}));
    files = files(ix);
end

%% ===== Helper: list all images recursively under root (robust) =====
function files = listImagesRecursive(root, allowed_ext)
    % Use dir with '**\*' to get all files, then filter by ext
    d = dir(fullfile(root, '**', '*'));
    d = d(~[d.isdir]);
    keep = false(size(d));
    for i = 1:numel(d)
        [~,~,e] = fileparts(d(i).name);
        if any(strcmpi(string(e), allowed_ext))
            keep(i) = true;
        end
    end
    files = d(keep);
end

%% Helper function: relative path
function rel = relPath(folder, rootpath)
    folder   = char(folder);
    rootpath = char(rootpath);
    if strncmpi(folder, rootpath, length(rootpath))
        rel = folder(length(rootpath)+1:end);
        if ~isempty(rel) && (rel(1)==filesep)
            rel = rel(2:end);
        end
    else
        rel = folder;
    end
end

%% Helper function: time string
function s = nowstr()
    s = datestr(now,'HH:MM:SS');
end

%% Helper function (overlay for debug only)
function Iout = overlayMaskLocal(I, BW, alpha, colorRGB)
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