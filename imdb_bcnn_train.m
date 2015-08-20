function imdb_bcnn_train(imdb, opts, varargin)
% Train a bilinear CNN model on a dataset supplied by imdb

opts.lite = false ;
opts.numFetchThreads = 0 ;
opts.train.batchSize = opts.batchSize ;
opts.train.numEpochs = 45 ;
opts.train.continue = true ;
opts.train.useGpu = false ;
opts.train.prefetch = false ;
opts.train.learningRate = [0.001*ones(1, 10) 0.001*ones(1, 10) 0.001*ones(1,10)] ;
opts.train.expDir = opts.expDir ;
opts.train.dataAugmentation = opts.dataAugmentation;
opts = vl_argparse(opts, varargin) ;


opts.inittrain.weightDecay = 0 ;
opts.inittrain.batchSize = 256 ;
opts.inittrain.numEpochs = 300 ;
opts.inittrain.continue = true ;
opts.inittrain.useGpu = false ;
opts.inittrain.prefetch = false ;
opts.inittrain.learningRate = 0.001 ;
opts.inittrain.expDir = fullfile(opts.expDir, 'init') ;
opts.inittrain.nonftbcnnDir = fullfile(opts.expDir, 'nonftbcnn');
 


if(opts.useGpu)
    opts.train.useGpu = opts.useGpu;
    opts.inittrain.useGpu = opts.useGpu;
end



net = initializeNetwork(imdb, opts) ;

shareWeights = ~isfield(net, 'netc');
 
if(~exist(fullfile(opts.expDir, 'fine-tuned-model'), 'dir'))
    mkdir(fullfile(opts.expDir, 'fine-tuned-model'))
end
   
if(shareWeights)
    fn = getBatchWrapper(net.normalization, opts.numFetchThreads, opts.bcnnScale, true) ;
    [net,info] = bcnn_train_sw(net, imdb, fn, opts.train, 'conserveMemory', true, 'scale', opts.bcnnScale) ;
    
    net = vl_simplenn_move(net, 'cpu');
    saveNetwork(fullfile(opts.expDir, 'fine-tuned-model', 'final-model.mat'), net);

else
    fn = getBatchWrapper(net.neta.normalization, opts.numFetchThreads) ;    
    [net,info] = bcnn_train(net, fn, imdb, opts.train, 'conserveMemory', true, 'scale', opts.bcnnScale) ;
    
    net.neta = vl_simplenn_move(net.neta, 'cpu');
    net.netb = vl_simplenn_move(net.netb, 'cpu');
    saveNetwork(fullfile(opts.expDir, 'fine-tuned-model', 'final-model-neta.mat'), net.neta);
    saveNetwork(fullfile(opts.expDir, 'fine-tuned-model', 'final-model-netb.mat'), net.netb);
end

% -------------------------------------------------------------------------
function saveNetwork(fileName, net)
% -------------------------------------------------------------------------
layers = net.layers;
% 
% % Replace the last layer with softmax
% layers{end}.type = 'softmax';
% layers{end}.name = 'prob';

% Remove fields corresponding to training parameters
ignoreFields = {'filtersMomentum', ...
                'biasesMomentum',...
                'filtersLearningRate',...
                'biasesLearningRate',...
                'filtersWeightDecay',...
                'biasesWeightDecay',...
                'class'};
for i = 1:length(layers),
    layers{i} = rmfield(layers{i}, ignoreFields(isfield(layers{i}, ignoreFields)));
end
classes = net.classes;
normalization = net.normalization;
save(fileName, 'layers', 'classes', 'normalization');


% -------------------------------------------------------------------------
function fn = getBatchWrapper(opts, numThreads)
% -------------------------------------------------------------------------
fn = @(imdb,batch,augmentation, doResize, scale) getBatch(imdb,batch,augmentation,doResize, scale, opts,numThreads) ;

% -------------------------------------------------------------------------
function [im,labels] = getBatch(imdb, batch, augmentation, doResize, scale, opts, numThreads)
% -------------------------------------------------------------------------
images = strcat([imdb.imageDir '/'], imdb.images.name(batch)) ;
im = imdb_get_batch_bcnn(images, opts, ...
                            'numThreads', numThreads, ...
                            'prefetch', nargout == 0, 'augmentation', augmentation, 'doResize', doResize, 'scale', scale);
labels = imdb.images.label(batch) ;
numAugments = size(im,4)/numel(batch);
labels = reshape(repmat(labels, numAugments, 1), 1, size(im,4));



function [im,labels] = getBatch_bcnn_fromdisk(imdb, batch, opts, numThreads)
% -------------------------------------------------------------------------
% images = strcat([imdb.imageDir '/'], imdb.images.name(batch)) ;
% im = imdb_get_batch(images, opts, ...
%                             'numThreads', numThreads, ...
%                             'prefetch', nargout == 0);
im = cell(1, numel(batch));
for i=1:numel(batch)
    load(fullfile(imdb.imageDir, imdb.images.name{batch(i)}));
    im{i} = code;
end
im = cat(2, im{:});
im = reshape(im, 1, 1, size(im,1), size(im, 2));
labels = imdb.images.label(batch) ;



function net = initializeNetwork(imdb, opts)
% -------------------------------------------------------------------------

% get encoder setting
encoderOpts.type = 'bcnn';
encoderOpts.modela = [];
encoderOpts.layera = 14;
encoderOpts.modelb = [];
encoderOpts.layerb = 14;
encoderOpts.shareWeight = false;

encoderOpts = vl_argparse(encoderOpts, opts.encoders{1}.opts);

scal = 1 ;
init_bias = 0.1;
numClass = length(imdb.classes.name);
    
%% the case using two networks
if ~encoderOpts.shareWeight
    
    assert(~isempty(encoderOpts.modela) && ~isempty(encoderOpts.modelb), 'at least one of the network is not specified')
    

    encoder.neta = load(encoderOpts.modela);
    encoder.neta.layers = encoder.neta.layers(1:encoderOpts.layera);
    encoder.netb = load(encoderOpts.modelb);
    encoder.netb.layers = encoder.netb.layers(1:encoderOpts.layerb);
    encoder.regionBorder = 0.05;
    encoder.type = 'bcnn';
    encoder.normalization = 'sqrt_L2';
    if opts.useGpu
        encoder.neta = vl_simplenn_move(encoder.neta, 'gpu') ;
        encoder.netb = vl_simplenn_move(encoder.netb, 'gpu') ;
        encoder.neta.useGpu = true ;
        encoder.netb.useGpu = true ;
    else
        encoder.neta = vl_simplenn_move(encoder.neta, 'cpu') ;
        encoder.netb = vl_simplenn_move(encoder.netb, 'cpu') ;
        encoder.neta.useGpu = false ;
        encoder.netb.useGpu = false ;
    end
    
    net.neta = encoder.neta;
    net.netb = encoder.netb;
    
    netc.layers = {};
    
    for i=numel(net.neta.layers):-1:1
        if strcmp(net.neta.layers{i}.type, 'conv')
            idx = i;
            break;
        end
    end
    ch1 = numel(net.neta.layers{idx}.biases);
    
    for i=numel(net.netb.layers):-1:1
        if strcmp(net.netb.layers{i}.type, 'conv')
            idx = i;
            break;
        end
    end
    ch2 = numel(net.netb.layers{idx}.biases);    
    dim = ch1*ch2;
    
    % randomly initialize the layers on top
    initialW = 0.001/scal *randn(1,1,dim, numClass,'single');
    initialBias = init_bias.*ones(1, numClass, 'single');
    
        
    netc.layers = {};
    net.netc.layers = {};
    net.netc.layers{end+1} = struct('type', 'sqrt');
    net.netc.layers{end+1} = struct('type', 'l2norm');    
        
    netc.layers{end+1} = struct('type', 'conv', ...
        'filters', initialW, ...
        'biases', initialBias, ...
        'stride', 1, ...
        'pad', 0, ...
    'filtersLearningRate', 1000, ...
    'biasesLearningRate', 1000, ...
    'filtersWeightDecay', 0, ...
    'biasesWeightDecay', 0) ;


    netc.layers{end+1} = struct('type', 'softmaxloss') ;
    
    % fine-tuning the fully-connected layers for initialization
    if(opts.bcnnLRinit)
        if exist(fullfile(opts.expDir, 'initial_fc.mat'))
            load(fullfile(opts.expDir, 'initial_fc.mat'), 'netc') ;
            %     netc.layers{1}.filtersLearningRate = 10;
            %     netc.layers{1}.biasesLearningRate = 10;
            %
            %     netc.layers{4}.filtersLearningRate = 10;
            %     netc.layers{4}.biasesLearningRate = 10;
        else
            
            %{
            % fully connected layer
            fcdim = 1000;
            netc.layers{end+1} = struct('type', 'conv', ...
                'filters', 0.001/scal *randn(1,1,dim, fcdim,'single'), ...
                'biases', init_bias.*ones(1, fcdim, 'single'), ...
                'stride', 1, ...
                'pad', 0, ...
                'filtersLearningRate', 1000, ...
                'biasesLearningRate', 1000, ...
                'filtersWeightDecay', 0, ...
             'biasesWeightDecay', 0) ;
        
            netc.layers{end+1} = struct('type', 'relu') ;
            netc.layers{end+1} = struct('type', 'dropout', ...
                           'rate', 0.5) ;
        
            netc.layers{end+1} = struct('type', 'conv', ...
             'filters', 0.001/scal *randn(1,1,fcdim, numClass,'single'), ...
             'biases', init_bias.*ones(1, numClass, 'single'), ...
             'stride', 1, ...
                'pad', 0, ...
                'filtersLearningRate', 1000, ...
                'biasesLearningRate', 1000, ...
                'filtersWeightDecay', 0, ...
                'biasesWeightDecay', 0) ;

            %}
            
            
            trainIdx = find(ismember(imdb.images.set, [1 2]));
            testIdx = find(ismember(imdb.images.set, 3));
            
            % get bilinear cnn features
            if ~exist(opts.inittrain.nonftbcnnDir)
                mkdir(opts.inittrain.nonftbcnnDir)
                batchSize = 10000;
                for b=1:ceil(numel(trainIdx)/batchSize)
                    idxEnd = min(numel(trainIdx), b*batchSize);
                    idx = trainIdx((b-1)*batchSize+1:idxEnd);
                    codeCell = encoder_extract_for_images(encoder, imdb, imdb.images.id(idx), 'concatenateCode', false, 'scale', opts.bcnnScale);
                    for i=1:numel(codeCell)
                        code = codeCell{i};
                        savefast(fullfile(opts.inittrain.nonftbcnnDir, ['bcnn_nonft_', num2str(idx(i), '%05d')]), 'code');
                    end
                end
            end
            
            
            bcnndb = imdb;
            tempStr = sprintf('%05d\t', trainIdx);
            tempStr = textscan(tempStr, '%s', 'delimiter', '\t');
            bcnndb.images.name = strcat('bcnn_nonft_', tempStr{1}');
            bcnndb.images.id = bcnndb.images.id(trainIdx);
            bcnndb.images.label = bcnndb.images.label(trainIdx);
            bcnndb.images.set = bcnndb.images.set(trainIdx);
            bcnndb.imageDir = opts.inittrain.nonftbcnnDir;
            
            % fine-tuning
            [netc, info] = cnn_train(netc, bcnndb, @getBatch_bcnn_fromdisk, opts.inittrain, ...
                'batchSize', opts.inittrain.batchSize, 'weightDecay', opts.inittrain.weightDecay, ...
                'conserveMemory', true, 'expDir', opts.inittrain.expDir);
            
            save(fullfile(opts.expDir, 'initial_fc.mat'), 'netc', '-v7.3') ;
        end
    end
    % initialize fully-connected layers
    for i=1:numel(netc.layers)
        net.netc.layers{end+1} = netc.layers{i};
    end

   
else
    %% the case with shared weights
    

    assert(strcmp(encoderOpts.modela, encoderOpts.modelb), 'neta and netb are required to be the same');    
    assert(~isempty(encoderOpts.modela), 'network is not specified');
        
    net = load(encoderOpts.modela); % Load model if specified
%     net = load(fullfile('data/models', opts.model)); % Load model if specified
    fprintf('Initializing from model: %s\n', opts.model);
    maxLayer = max(encoderOpts.layera, encoderOpts.layerb);

    net.layers = net.layers(1:maxLayer);
    
    
    for i=encoderOpts.layera:-1:1
        if strcmp(net.layers{i}.type, 'conv')
            idx = i;
            break;
        end
    end
    mapSize1 = numel(net.layers{idx}.biases);
    
    
    for i=encoderOpts.layerb:-1:1
        if strcmp(net.layers{i}.type, 'conv')
            idx = i;
            break;
        end
    end
    mapSize2 = numel(net.layers{idx}.biases);
    
    net.layers{end+1} = struct('type', 'bilinearpool');
    net.layers{end+1} = struct('type', 'sqrt');
    net.layers{end+1} = struct('type', 'l2norm');
    
    
    initialW = 0.001/scal * randn(1,1,mapSize1*mapSize2,numClass,'single');
    initialBias = init_bias.*ones(1, numClass, 'single');
    
    netc.layers{end+1} = struct('type', 'conv', ...
                'filters', initialW, ...
                'biases', initialBias, ...
                'stride', 1, ...
                'pad', 0, ...
                'filtersLearningRate', 1000, ...
                'biasesLearningRate', 1000, ...
                'filtersWeightDecay', 0, ...
                'biasesWeightDecay', 0) ;
            
            
    netc.layers{end+1} = struct('type', 'softmaxloss') ;
    
    %% do logistic regression initialization
    %==========================================================================================
 
    if(opts.bcnnLRinit)
        netInit = net;
       
        
        if opts.train.useGpu
            netInit = vl_simplenn_move(netInit, 'gpu') ;
        end
        train = find(imdb.images.set==1);
        batchSize = opts.inittrain.batchSize;
        getBatchFn = getBatchWrapper(netInit.normalization, opts.numFetchThreads, opts.bcnnScale);
        
        
        if exist(opts.inittrain.nonftbcnnDir)
            load(fullfile(opts.inittrain.nonftbcnnDir, ['bcnn_nonft_', num2str(train(1), '%05d'), '.mat']));
        else
            mkdir(opts.inittrain.nonftbcnnDir)
            for t=1:batchSize:numel(train)
                fprintf('Initialization: extracting bcnn feature of batch %d/%d\n', ceil(t/batchSize), ceil(numel(train)/batchSize));
                batch = train(t:min(numel(train), t+batchSize-1));
                [im, labels] = getBatchFn(imdb, batch, opts.dataAugmentation{1}) ;
                if opts.train.prefetch
                    nextBatch = train(t+batchSize:min(t+2*batchSize-1, numel(train))) ;
                    getBatch(imdb, nextBatch, opts.dataAugmentation{1}) ;
                end
                if opts.train.useGpu
                    im = gpuArray(im) ;
                end
                net.layers{end}.class = labels ;
                
                res = [] ;
                res = vl_bilinearnn(netInit, im, [], res, ...
                    'disableDropout', true, ...
                    'conserveMemory', true, ...
                    'sync', true) ;
                
                codeb = squeeze(res(end).x);
                
                for i=1:numel(batch)
                    code = codeb(:,i);
                    savefast(fullfile(opts.inittrain.nonftbcnnDir, ['bcnn_nonft_', num2str(batch(i), '%05d')]), 'code');
                end
            end
        end
        
        netc.layers = {};
        clear code res netInit
        
        if exist(fullfile(opts.expDir, 'initial_fc.mat'), 'file')
            load(fullfile(opts.expDir, 'initial_fc.mat'), 'netc') ;
        else
            
            
            bcnndb = imdb;
            tempStr = sprintf('%05d\t', train);
            tempStr = textscan(tempStr, '%s', 'delimiter', '\t');
            bcnndb.images.name = strcat('bcnn_nonft_', tempStr{1}');
            bcnndb.images.id = bcnndb.images.id(train);
            bcnndb.images.label = bcnndb.images.label(train);
            bcnndb.images.set = bcnndb.images.set(train);
            bcnndb.imageDir = opts.inittrain.nonftbcnnDir;
            
            [netc, info] = cnn_train(netc, bcnndb, @getBatch_bcnn_fromdisk, opts.inittrain, ...
                'batchSize', opts.inittrain.batchSize, 'weightDecay', opts.inittrain.weightDecay, ...
                'conserveMemory', true, 'expDir', opts.inittrain.expDir);
            
            save(fullfile(opts.expDir, 'initial_fc.mat'), 'netc') ;
        end
        
%         initialW = gather(netc.layers{1}.filters);
%         initialBias = gather(netc.layers{1}.biases);
%         clear netc
    end
    %==========================================================================================
    for i=1:numel(netc.layers)
        net.layers{end+1} = netc.layers{i};
    end
	
      
    % Rename classes
    net.classes.name = imdb.classes.name;
    net.classes.description = imdb.classes.name;
    
end


function code = encoder_extract_for_images(encoder, imdb, imageIds, varargin)
% -------------------------------------------------------------------------
opts.batchSize = 128 ;
opts.maxNumLocalDescriptorsReturned = 500 ;
opts.concatenateCode = true;
opts.scale = 2;
opts = vl_argparse(opts, varargin) ;

[~,imageSel] = ismember(imageIds, imdb.images.id) ;
imageIds = unique(imdb.images.id(imageSel)) ;
n = numel(imageIds) ;

% prepare batches
n = ceil(numel(imageIds)/opts.batchSize) ;
% batches = mat2cell(1:numel(imageIds), 1, [opts.batchSize * ones(1, n-1), numel(imageIds) - opts.batchSize*(n-1)]) ;
batches = mat2cell(1:numel(imageIds), 1, [opts.batchSize * ones(1, n-1), numel(imageIds) - opts.batchSize*(n-1)]) ;
batchResults = cell(1, numel(batches)) ;

% just use as many workers as are already available
numWorkers = matlabpool('size') ;
%parfor (b = 1:numel(batches), numWorkers)
for b = numel(batches):-1:1
  batchResults{b} = get_batch_results(imdb, imageIds, batches{b}, ...
                        encoder, opts.maxNumLocalDescriptorsReturned, opts.scale) ;
end
%{
code = zeros(size(batchResults{b}.code{1},1), numel(imageIds), 'single');
for b=1:numel(batches)
    m = numel(batches{b});
    for j=1:m
        code(:,batches{b}(j)) = batcheResults{b}.code{j};
    end
end
%}

code = cell(size(imageIds)) ;
for b = 1:numel(batches)
  m = numel(batches{b});
  for j = 1:m
      k = batches{b}(j) ;
      code{k} = batchResults{b}.code{j};
  end
end

if opts.concatenateCode
    clear batchResults
   code = cat(2, code{:}) ;
   % code = cell2mat(code);
end


function result = get_batch_results(imdb, imageIds, batch, encoder, maxn, scale)
% -------------------------------------------------------------------------
m = numel(batch) ;
im = cell(1, m) ;
task = getCurrentTask() ;
if ~isempty(task), tid = task.ID ; else tid = 1 ; end
for i = 1:m
  fprintf('Task: %03d: encoder: extract features: image %d of %d\n', tid, batch(i), numel(imageIds)) ;
  im{i} = imread(fullfile(imdb.imageDir, imdb.images.name{imdb.images.id == imageIds(batch(i))}));
  if size(im{i}, 3) == 1, im{i} = repmat(im{i}, [1 1 3]);, end; %grayscale image
end

if ~isfield(encoder, 'numSpatialSubdivisions')
    encoder.numSpatialSubdivisions = 1 ;
end
code_ = get_bcnn_features(encoder.neta, encoder.netb,...
    im, ...
    'regionBorder', encoder.regionBorder, ...
    'normalization', encoder.normalization, ...
    'scales', scale);
    
result.code = code_ ;
