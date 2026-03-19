%% ROI visualization + mean brightness per ROI
% Opens a save dialog so the user can choose where to save the final image
% Saves final image in high quality without title, axes, or white border

clc; clear; close all;

%% === USER INPUT ===
bildOrdner = 'PATH TO IMAGE';
bildName   = 'IMAGE NAME WITH FORMAT';

% Camera calibration file
cameraParamsFile = 'PATH\camera_Calibration_Parameters.mat';

bildPfad = fullfile(bildOrdner, bildName);

%% === Load camera parameters ===
if ~isfile(cameraParamsFile)
    error("Camera parameter file not found: %s", cameraParamsFile);
end

S = load(cameraParamsFile, 'cameraParams');
cameraParams = S.cameraParams;

%% === Load image ===
if ~isfile(bildPfad)
    error("Image not found: %s", bildPfad);
end

img = imread(bildPfad);

% Convert RGB to grayscale if needed
if ndims(img) == 3
    img_gray = rgb2gray(img);
else
    img_gray = img;
end

% Convert to uint8 for stable undistortion input
img_gray = im2uint8(img_gray);

%% === Undistort image ===
img_gray = undistortImage(img_gray, cameraParams);

% Convert to double for mean calculation
img_gray_double = double(img_gray);

%% === ROI definition ===
r1 = 651:1000;   c1 = 125:550;     % left ROI
r2 = 651:1000;   c2 = 1040:1300;   % right ROI

%% === Clamp ROIs to image size ===
[h, w] = size(img_gray_double);

r1 = r1(r1 >= 1 & r1 <= h);
c1 = c1(c1 >= 1 & c1 <= w);

r2 = r2(r2 >= 1 & r2 <= h);
c2 = c2(c2 >= 1 & c2 <= w);

if isempty(r1) || isempty(c1)
    error('Left ROI is outside the image.');
end
if isempty(r2) || isempty(c2)
    error('Right ROI is outside the image.');
end

%% === Extract ROI values and compute mean brightness ===
region1 = img_gray_double(r1, c1);
region2 = img_gray_double(r2, c2);

mean1 = mean(region1(:), 'omitnan');
mean2 = mean(region2(:), 'omitnan');

%% === Rectangle positions ===
rect1 = [min(c1), min(r1), max(c1)-min(c1), max(r1)-min(r1)];
rect2 = [min(c2), min(r2), max(c2)-min(c2), max(r2)-min(r2)];

%% === Text positions ===
textPos1_x = min(c1) + 10;
textPos1_y = min(r1) + 40;

textPos2_x = min(c2) + 10;
textPos2_y = min(r2) + 40;

%% === Display image ===
fig = figure('Color', 'w', ...
             'MenuBar', 'none', ...
             'ToolBar', 'none', ...
             'NumberTitle', 'off', ...
             'Name', 'ROI visualization', ...
             'InvertHardcopy', 'off');

ax = axes('Parent', fig, 'Units', 'normalized', 'Position', [0 0 1 1]);

imshow(img_gray, [], 'Parent', ax);
hold(ax, 'on');

rectangle(ax, 'Position', rect1, 'EdgeColor', 'g', 'LineWidth', 3);
rectangle(ax, 'Position', rect2, 'EdgeColor', 'r', 'LineWidth', 3);

text(ax, textPos1_x, textPos1_y, sprintf('%.2f', mean1), ...
    'Color', 'g', ...
    'FontSize', 18, ...
    'FontWeight', 'bold', ...
    'Interpreter', 'none', ...
    'Margin', 1);

text(ax, textPos2_x, textPos2_y, sprintf('%.2f', mean2), ...
    'Color', 'r', ...
    'FontSize', 18, ...
    'FontWeight', 'bold', ...
    'Interpreter', 'none', ...
    'Margin', 1);

hold(ax, 'off');

axis(ax, 'off');
set(ax, 'LooseInset', [0 0 0 0]);

%% === Ask user where to save ===
[saveName, savePath, filterIndex] = uiputfile( ...
    {'*.png', 'PNG image (*.png)'; ...
     '*.tif', 'TIFF image (*.tif)'; ...
     '*.jpg', 'JPEG image (*.jpg)'}, ...
    'Save ROI image as', ...
    fullfile(bildOrdner, 'output_ROI.png'));

if isequal(saveName, 0) || isequal(savePath, 0)
    disp('Save operation cancelled by user.');
    return;
end

outputFile = fullfile(savePath, saveName);

%% === High-quality export ===
drawnow;

% Export the full figure at high resolution
exportgraphics(fig, outputFile, ...
    'Resolution', 600, ...
    'BackgroundColor', 'white', ...
    'ContentType', 'image');

%% === Console output ===
fprintf('Image used for visualization and analysis: UNDISTORTED image\n');
fprintf('Left ROI (green): %.2f\n', mean1);
fprintf('Right ROI (red): %.2f\n', mean2);
fprintf('Saved high-quality image: %s\n', outputFile);