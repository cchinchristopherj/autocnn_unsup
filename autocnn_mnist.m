% Demo code for training and prediction on MNIST with a 1-2 layer AutoCNN
% The code can work without parameters and dependencies
% However, consider the following parameters to improve speed and classification accuracy:
% opts.matconvnet (optional, recommended) - path to the MatConvNet root directory, e.g, /home/code/3rd_party/matconvnet
% opts.vlfeat (optional, recommended) - path to the VLFeat mex directory, e.g, /home/code/3rd_party/vlfeat/toolbox/mex/mexa64
%
% opts.n_train (optional) - number of labeled training samples (default: full test)
% opts.arch (optional) - network architecture (default: large 2 layer network)
% opts.dataDir (optional) - directory with MNIST data
% opts can contain other parameters

function test_results = autocnn_mnist(varargin)

time_start = clock;
fprintf('\ntest %s on %s \n', upper('started'), datestr(time_start))

if (nargin == 0)
    opts = [];
elseif (isstruct(varargin{1}))
    opts = varargin{1};
end

if (~isfield(opts,'whiten'))
    opts.whiten = false; % whitening is not applied
end
if (~isfield(opts,'batch_size'))
    opts.batch_size = 100;
end
if (~isfield(opts,'rectifier_param'))
    opts.rectifier_param = [0,Inf];
end
if (~isfield(opts,'rectifier'))
    opts.rectifier = 'abs';
end
if (~isfield(opts,'conv_norm'))
    opts.conv_norm = 'stat';
end
if (~isfield(opts,'arch'))
    opts.arch = '192c11-2p-conv1_3__32g-3ch-64c9-2p-conv2_3'; % define a 2 layer architecture
end

sample_size = [28,28,1];
opts.dataset = 'mnist';
opts.lcn_l2 = true; % local feature map normalization
opts.lcn = false; % LCN is turned off for MNIST
opts.net_init_fn = @() net_init(opts.arch, opts, 'sample_size', sample_size, varargin{:});
rootFolder = fileparts(mfilename('fullpath'));
if (~isfield(opts,'dataDir'))
    opts.dataDir = fullfile(rootFolder,'data/mnist');
end
if (~exist(opts.dataDir,'dir'))
    mkdir(opts.dataDir)
end
fprintf('loading and preprocessing data \n')
opts.sample_size = sample_size;
if (~isfield(opts,'val') || isempty(opts.val))
  opts.val = false; % true for cross-validation on the training set
end
[data_train, data_test] = load_MNIST_data(opts);

if (~isfield(opts,'n_folds'))
    opts.n_folds = 1;
end
if (~isfield(opts,'n_train'))
    opts.n_train = size(data_train.images,1);
end

net = opts.net_init_fn();
% PCA dimensionalities (p_j) for the SVM committee
if (~isfield(opts,'PCA_dim'))
    if (numel(net.layers) > 1)
        if (opts.n_train >= 60e3)
            opts.PCA_dim = [200,250,275,300,350,375,400];
        else
            opts.PCA_dim = [50,70,90,100,120,150:50:400];
        end
    else
        opts.PCA_dim = [50,70,90,100,120,150,200,250];
    end
end

for fold_id = 1:opts.n_folds
    
    opts.fold_id = fold_id;
    test_results = autocnn_unsup(data_train, data_test, net, opts);

    fprintf('test took %5.3f seconds \n', etime(clock,time_start));
    fprintf('test (fold %d/%d) %s on %s \n\n', fold_id, opts.n_folds, upper('finished'), datestr(clock))
    time_start = clock;
end

end

function [data_train, data_test] = load_MNIST_data(opts)
% adopted from the matconvnet example

files = {'train-images-idx3-ubyte', ...
         'train-labels-idx1-ubyte', ...
         't10k-images-idx3-ubyte', ...
         't10k-labels-idx1-ubyte'};

for i=1:numel(files)
    if (~exist(fullfile(opts.dataDir, files{i}), 'file'))
        url = sprintf('http://yann.lecun.com/exdb/mnist/%s.gz',files{i}) ;
        fprintf('downloading %s\n', url) ;
        gunzip(url, opts.dataDir) ;
    end
end

f=fopen(fullfile(opts.dataDir, 'train-images-idx3-ubyte'),'r');
x1=fread(f,inf,'uint8');
fclose(f);
data_train.images = reshape(permute(reshape(single(x1(17:end))./255,[opts.sample_size(1:2),60e3]),[3 2 1]),...
    [60e3,prod(opts.sample_size(1:2))]);
data_train.unlabeled_images = data_train.images;

f=fopen(fullfile(opts.dataDir, 'train-labels-idx1-ubyte'),'r');
y1=fread(f,inf,'uint8');
fclose(f);
data_train.labels = double(y1(9:end));

if (opts.val)
    % cross-validation mode
    all_ids = 1:size(data_train.images,1);
    train_ids = all_ids(randperm(length(all_ids), 10e3));
    test_ids = all_ids(~ismember(all_ids,train_ids));
    test_ids = test_ids(randperm(length(test_ids), 10e3));
    data_test.images = data_train.images(test_ids,:);
    data_test.labels = data_train.labels(test_ids);
    data_train.images = data_train.images(train_ids,:);
    data_train.labels = data_train.labels(train_ids);
    data_train.unlabeled_images = data_train.images;
else
    f=fopen(fullfile(opts.dataDir, 't10k-labels-idx1-ubyte'),'r');
    y2=fread(f,inf,'uint8');
    fclose(f);
    data_test.labels = double(y2(9:end));
    f=fopen(fullfile(opts.dataDir, 't10k-images-idx3-ubyte'),'r') ;
    x2=fread(f,inf,'uint8');
    fclose(f);
    data_test.images = reshape(permute(reshape(single(x2(17:end))./255,[opts.sample_size(1:2),10e3]),[3 2 1]),...
      [10e3,prod(opts.sample_size(1:2))]);
end

if (opts.whiten)
    fprintf('performing data whitening \n')
    opts.pca_dim = [];
    opts.pca_epsilon = 0.05;
    opts.pca_mode = 'zcawhiten';
    [data_train.images, PCA_matrix, data_mean, L_regul] = pca_zca_whiten(data_train.images, opts);
    data_test.images = pca_zca_whiten(data_test.images, opts, PCA_matrix, data_mean, L_regul);
end

% we use the first 4k-10k samples as unlabeled data, it's enough to learn filters and connections and perform PCA
if (isfield(opts,'fix_unlabeled') && opts.fix_unlabeled)
    opts.n_unlabeled = 60e3; % unlabeled and labeled images will be the same
elseif (~isfield(opts,'n_unlabeled') || isempty(opts.n_unlabeled))
    opts.n_unlabeled = 4e3;
end
unlabeled_ids = 1:opts.n_unlabeled;
data_train.unlabeled_images = data_train.unlabeled_images(unlabeled_ids,:);
data_train.unlabeled_images_whitened = data_train.images(unlabeled_ids,:);

end