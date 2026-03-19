%% Leaf-wise image brightness summary (two fixed regions per image)
%  - Search recursively for .bmp files
%  - Per image: mean / std / median brightness (Region1 ∪ Region2)
%  - Per folder: aggregation across images (from the per-image MEAN values)
%  - Excel output with 2 sheets: "Bilder" and "Ordner"
%  - Natural numeric sorting across multiple levels of RelPfad + Ordner/Bild
%  - NEW: Image undistortion using cameraParams (undistortImage) before evaluating the regions

clc; close all; clear;

%% Step 1 – Root folder
hauptordner = ['PATH_TO_ROOT_FOLDER'];
if ~endsWith(hauptordner, filesep)
    hauptordner = [hauptordner filesep];
end

%%% >>> NEW: Load camera parameters (once for all images)
S = load('PATH_TO_CAMERA_PARAMS_FILE\camera_Calibration_Parameters.mat', ...
         'cameraParams');
cameraParams = S.cameraParams;
fprintf('cameraParams loaded.\n');

%% Step 2 – Find all BMP files recursively
alleBmp = dir(fullfile(hauptordner, '**', '*.bmp'));  % recursive
if isempty(alleBmp)
    error('No BMP files found under %s', hauptordner);
end

%% Step 3 – Unique leaf folders (folders that contain images)
leafFolders = unique(string({alleBmp.folder}))';

%% Step 4 – Result containers
% Image level
rows_images = {};   % {relPath, leafName, fileName, meanH, stdH, medianH}
% Folder level
rows_folders = {};  % {relPath, leafName, meanAll, stdAll, medianAll, n}

%% Step 5 – Loop over leaf folders
for i = 1:numel(leafFolders)
    thisFolder = char(leafFolders{i});
    files = dir(fullfile(thisFolder, '*.bmp'));   % only directly inside this leaf folder

    if isempty(files)
        continue;
    end

    % Relative path + leaf name
    rel = erase(thisFolder, hauptordner);
    if startsWith(rel, filesep), rel = rel(2:end); end
    [~, leafName] = fileparts(thisFolder);

    % Store per-image metrics for later folder aggregation
    mean_per_image = nan(numel(files),1);

    for k = 1:numel(files)
        imgPath = fullfile(files(k).folder, files(k).name);
        img = imread(imgPath);
        if ndims(img) == 3
            img = rgb2gray(img);
        end

        img = im2uint8(img);  % stable 0–255 range

        %%% >>> NEW: Apply image undistortion
        % Operates on the grayscale image; output size usually remains unchanged.
        img = undistortImage(img, cameraParams);

        img = double(img);  % convert to double afterwards for mean/std/median
%%
        % --- Fixed regions (Spheres) ---
        r1 = 651:1000;   c1 = 125:550;     % top-left (Y:X)
        r2 = 651:1000;   c2 = 1040:1300;   % top-right (Y:X)

                % --- Fixed regions (Fermentation: DAY 1+2) ---
        % r1 = 351:750;   c1 = 125:580;     % top-left (Y:X)
        % r2 = 351:750;   c2 = 1040:1330;   % top-right (Y:X)

               % --- Fixed regions (Fermentation: DAY 3-10) ---
        % r1 = 1:400;   c1 = 125:580;     % top-left (Y:X)
        % r2 = 1:400;   c2 = 1040:1330;   % top-right (Y:X)
        %%
        % Minimal robustness: clamp to image size
        h = size(img,1); w = size(img,2);
        r1 = r1(r1>=1 & r1<=h); c1 = c1(c1>=1 & c1<=w);
        r2 = r2(r2>=1 & r2<=h); c2 = c2(c2>=1 & c2<=w);

        if isempty(r1) || isempty(c1) || isempty(r2) || isempty(c2)
            vals = NaN;
        else
            region1 = img(r1, c1);
            region2 = img(r2, c2);
            vals = [region1(:); region2(:)];
        end

        % --- Image metrics ---
        m  = mean(vals, 'omitnan');
        s  = std(vals, 0, 'omitnan');      % standard deviation
        md = median(vals, 'omitnan');      % exact median of the pixel values

        mean_per_image(k) = m;

        % Row for sheet "Bilder"
        rows_images(end+1,1:6) = { ...
            rel, ...
            leafName, ...
            files(k).name, ...
            m, s, md ...
        };
    end

    % --- Folder aggregation across images (from the per-image MEAN values) ---
    meanAll   = mean(mean_per_image, 'omitnan');
    stdAll    = std(mean_per_image, 0, 'omitnan');
    medianAll = median(mean_per_image, 'omitnan');
    nImgs     = sum(~isnan(mean_per_image));

    rows_folders(end+1,1:6) = { ...
        rel, ...
        leafName, ...
        meanAll, stdAll, medianAll, nImgs ...
    };
end

%% Step 6 – Convert to tables
T_images = cell2table(rows_images, 'VariableNames', ...
    {'RelPfad','Ordner','Bildname','Mean_H','Std_H','Median_H'});

T_folders = cell2table(rows_folders, 'VariableNames', ...
    {'RelPfad','Ordner','Mean_H_Ordner','Std_H_Ordner','Median_H_Ordner','N_Bilder'});

%% Step 7 – Natural numeric sorting
% 7a) RelPfad: multi-level natural numeric sorting (each level numeric, letters ignored)
[T_images, relSortVars_img, auxCols_img]   = addRelPathNaturalSortCols(T_images,  'RelPfad');
[T_folders, relSortVars_fold, auxCols_fold]= addRelPathNaturalSortCols(T_folders, 'RelPfad');

% 7b) Sort folder and image names numerically (first number in the name)
T_images.OrdnerNum = firstnum(T_images.Ordner);
T_images.BildNum   = firstnum(T_images.Bildname);
T_folders.OrdnerNum = firstnum(T_folders.Ordner);

% 7c) Define sorting order
sortVars_images  = [relSortVars_img, {'OrdnerNum','Ordner','BildNum','Bildname'}];
sortVars_folders = [relSortVars_fold, {'OrdnerNum','Ordner'}];

% 7d) Sort tables
T_images  = sortrows(T_images,  sortVars_images);
T_folders = sortrows(T_folders, sortVars_folders);

% 7e) Remove helper columns again
T_images(:, auxCols_img)    = [];
T_folders(:, auxCols_fold)  = [];
T_images.OrdnerNum = [];
T_images.BildNum   = [];
T_folders.OrdnerNum = [];

%% Step 8 – Write Excel file with 2 sheets
timestamp     = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
dateiname     = ['Bildhelligkeit_2Sheets_', timestamp, '.xlsx'];
ergebnisDatei = fullfile(hauptordner, dateiname);

writetable(T_images,  ergebnisDatei, 'FileType','spreadsheet', 'Sheet','Bilder');
writetable(T_folders, ergebnisDatei, 'FileType','spreadsheet', 'Sheet','Ordner');

fprintf('Excel written: %s\n -> Sheets: "Bilder", "Ordner"\n', ergebnisDatei);

%% ===================== Helper functions =====================

function v = firstnum(strs)
% FIRSTNUM: extracts the first number from each string/char.
% Examples: 'b12'->12, 'bild_003a'->3, 'X'->NaN
s = string(strs);
v = nan(numel(s),1);
for i = 1:numel(s)
    m = regexp(s(i), '\d+', 'match', 'once');  % first match
    if ~isempty(m)
        v(i) = str2double(m);
    end
end
end

function [T, sortVarNames, auxColNames] = addRelPathNaturalSortCols(T, relVarName)
% addRelPathNaturalSortCols:
%  Splits RelPfad into segments and generates for each segment:
%   - a numeric key (first number; NaN->Inf)
%   - a text key (empty/missing -> '~~~~' so it is sorted at the end)
%  Returns:
%    T            – table with additional helper columns
%    sortVarNames – sorting order (Num1, Text1, Num2, Text2, ...)
%    auxColNames  – names of the added helper columns (to remove later)

    s = string(T.(relVarName));
    parts = split(s, string(filesep));      % NxK string array
    if iscolumn(parts); parts = parts.'; end 
    maxSeg = size(parts,2);

    sortVarNames = {};
    auxColNames  = {};

    for j = 1:maxSeg
        segText = parts(:,j);

        % missing/empty -> '~~~~' (ensures shorter paths are sorted at the end)
        isMissing = ismissing(segText) | (strlength(segText)==0);
        segText(isMissing) = "~~~~";

        % numeric key from the first number
        segNum = firstnum(segText);         % NaN if no number is present
        segNum(isnan(segNum)) = inf;        % no number -> sort to the end of that level

        % Column names
        numName  = sprintf('RelSeg%02d_Num',  j);
        textName = sprintf('RelSeg%02d_Text', j);

        % Write into table
        T.(numName)  = segNum;
        T.(textName) = segText;

        sortVarNames = [sortVarNames, {numName, textName}]; 
        auxColNames  = [auxColNames,  {numName, textName}]; 
    end
end