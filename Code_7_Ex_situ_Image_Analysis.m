% Verzeichnisse
inputFolder = 'PATH TO FOLDER';
outputFolder = 'PATH TO OUTPUT FOLDER FOR IMAGES';
excelPath = 'OUTPUT PATH\pelletdaten.xlsx';

% Parameter
scaleFactor = 0.1;
px_per_mm = 93 * scaleFactor;
mm_per_px = 1 / px_per_mm;
maxAspectRatio = 3;
maxLengthPx = 1000;
minArea_mm2 = 0.5;
grayThreshold = 190; % feste Helligkeitsschwelle (0 = schwarz, 255 = weiß)
randAbstand = 20;

% Bilddateien finden
files = dir(fullfile(inputFolder, '*.jpg'));

% Tabelle für Mediane vorbereiten
medianTable = table('Size', [0 3], ...
    'VariableTypes', {'string', 'double', 'double'}, ...
    'VariableNames', {'Bildname', 'Median_Area_mm2', 'Median_Circularity'});

for i = 1:length(files)
    imgPath = fullfile(files(i).folder, files(i).name);
    [~, name, ~] = fileparts(imgPath);
    img = imread(imgPath);
    img_resized = imresize(img, scaleFactor);
    gray = rgb2gray(img_resized);

    [centers, radii] = imfindcircles(gray, ...
        [round(min(size(gray))/2.5), round(max(size(gray))/1.5)], ...
        'Sensitivity', 0.98, 'EdgeThreshold', 0.05, 'ObjectPolarity', 'bright');

    if ~isempty(centers)
        centerX = centers(1,1);
        centerY = centers(1,2);
        radius = radii(1);
        radiusInner = radius - randAbstand;
        [X, Y] = meshgrid(1:size(gray,2), 1:size(gray,1));
        circularMask = ((X - centerX).^2 + (Y - centerY).^2) <= radiusInner^2;
    else
        warning('Kein Kreis gefunden – keine Maskierung angewendet.');
        circularMask = true(size(gray));
    end

    gray(~circularMask) = 255;

    bw = imbinarize(gray, 'adaptive', 'ForegroundPolarity', 'dark', 'Sensitivity', 0.55);
    bw = imcomplement(bw);
    bw = bwareaopen(bw, 30);
    se = strel('disk', 1);
    bw = imerode(bw, se);
    bw = imdilate(bw, se);

    L = bwlabel(bw);
    [B, ~] = bwboundaries(bw, 'noholes');
    stats = regionprops(L, gray, 'Area', 'Centroid', 'BoundingBox', 'PixelValues', 'Perimeter');

    validStats = [];
    validB = {};
    areas_mm2 = [];
    meanGrayValues = [];
    circularities = [];

    for k = 1:length(stats)
        c = stats(k).Centroid;
        bbox = stats(k).BoundingBox;
        width = bbox(3);
        height = bbox(4);
        longSide = max(width, height);
        aspectRatio = longSide / max(1, min(width, height));
        area_mm2 = stats(k).Area * (mm_per_px)^2;
        meanGray = mean(stats(k).PixelValues);
        perimeter = stats(k).Perimeter;
        circularity = 4 * pi * stats(k).Area / (perimeter^2);

        boundary = B{k};
        rows = round(boundary(:,1));
        cols = round(boundary(:,2));
        validIdx = rows > 0 & rows <= size(circularMask,1) & ...
                   cols > 0 & cols <= size(circularMask,2);
        insideCircle = circularMask(sub2ind(size(circularMask), rows(validIdx), cols(validIdx)));
        maskCheck = all(insideCircle);

        % Feste Helligkeitsschwelle
        if aspectRatio < maxAspectRatio && ...
           longSide < maxLengthPx && ...
           area_mm2 >= minArea_mm2 && ...
           meanGray < grayThreshold && ...
           maskCheck
            validStats = [validStats; stats(k)];
            validB{end+1} = boundary;
            areas_mm2(end+1) = area_mm2;
            meanGrayValues(end+1) = meanGray;
            circularities(end+1) = circularity;
        end
    end

    medianArea = median(areas_mm2);
    medianCirc = median(circularities);
    medianTable = [medianTable; {name, medianArea, medianCirc}];

    figure('Visible', 'off');
    imshow(img_resized);
    hold on;

    for k = 1:length(validStats)
        boundary = validB{k};
        plot(boundary(:,2), boundary(:,1), 'g', 'LineWidth', 1);
        c = validStats(k).Centroid;
        text(c(1), c(2), sprintf('%d\n%.1f', k, meanGrayValues(k)), ...
            'Color', 'r', 'FontSize', 5, 'HorizontalAlignment', 'center');
    end

    if ~isempty(centers)
        viscircles(centers, radii, 'Color', 'b', 'LineWidth', 1);
        viscircles(centers, radiusInner, 'Color', 'c', 'LineStyle', '--');
    end

    hold off;
    title(['Gefilterte Pellets: ' name]);

    outputImagePath = fullfile(outputFolder, [name '_pellets_markiert.jpg']);
    saveas(gcf, outputImagePath);
    close;

    T = table((1:length(validStats))', areas_mm2', meanGrayValues', circularities', ...
        'VariableNames', {'PelletID', 'Area_mm2', 'MeanGrayValue', 'Circularity'});
    writetable(T, excelPath, 'Sheet', name);
end

writetable(medianTable, excelPath, 'Sheet', 'Medianflächen');
disp('Alle Bilder verarbeitet, feste Helligkeitsschwelle verwendet, Kreis erkannt.');