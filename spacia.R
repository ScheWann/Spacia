###########  Libraries  ###########
library(Rcpp)
library(RcppProgress)
library(rjson)
library("optparse")
library(ggplot2)
library(patchwork)
library(scales)
library(gridExtra)
library(dplyr)
library(filelock)
library(data.table)
library(jsonlite)

###########  Options  ###########
option_list = list(
  make_option(c("-x", "--inputExpression"), type="character",
              default=NULL,
              help='gene expression matrix [default = %default]\n\t\t\tFormat: cell x gene expression values. Column names should be "cell" followed by gene names. Same as in spacia.py, expression values should be normalized and log-transformed. Option "-C" can be used if using raw counts to perform a simple transformation',
              metavar="character"),
  make_option(c("-m", "--inputMeta"), type="character",
              default=NULL,
              help='input metadata [default = %default]\n\t\t\tTable of location and cell type info with each cell taking one row. Must contain cell names as first column as well as columns "X","Y", and "cell_type"',
              metavar="character"),
  make_option(c("-C", "--isCount"), action="store_true", default=FALSE,
              help="gene expression matrix consists of raw counts"),
  make_option(c("-a", "--spacia_path"), type="character", default=NULL,
              help="path to spacia core code [default = %default]\n\t\tThe path to directory containing:\n\t\t\tFun_MICProB_C2Cinter.cpp\n\t\t\tMICProB_MIL_C2Cinter.R\n\t\t\tMIL_wrapper.R",
              metavar="character"),
  make_option(c("-r", "--receivingCell"), type="character", default=NULL,
              help="receiving cell type [default = %default]", metavar="character"),
  make_option(c("-s", "--sendingCell"), type="character", default=NULL,
              help="sending cell type [default = %default]", metavar="character"),
  make_option(c("-g", "--receivingGene"), type="character", default=NULL,
              help="receiving gene (can be a text file of one gene per line) [default = %default]", metavar="character"),
  make_option(c("-o", "--output"), type="character", default=NULL,
              help="output file name prefix", metavar="character"),
  make_option(c("-f", "--overwrite"), action="store_true", default=FALSE,
              help="overwrite existing output [default = %default]"),
  make_option(c("-t", "--paramTable"), type="character", default=NULL,
              help="optional csv of cor_cutoff and exp_receiver_quantile for each receiving gene\n\t\t***mandatory if using multiple receiving genes from file***\n\t\tmust contain columns:\n\t\t\tgene_name,cor_cutoff,quantile_cutoff",
              metavar="character"),
  make_option(c('-q', '--quantile'), type='double', default=NULL,
              help='receiving gene quantile cutoff, overwrites -t [default = %default]\n\t\tcutoff used to dichotomize the receiving gene signature',
              metavar = 'number'),
  make_option(c('-u', '--corCut'), type='double', default=NULL,
              help='receiving gene cor. cutoff, overwrites -t [default = %default]\n\t\tcorrelation value cutoff used in choosing genes to construct a signature of the receiving gene; this reduces dropout',
              metavar = 'number'),
  make_option(c('-d', '--dist'), type='double', default=50,
              help='distance cutoff [default = %default]', metavar = 'number'),
  make_option(c('-p', '--path'), type='integer', default=50,
              help='number of principle components to use [default = %default]', metavar = 'number'),
  make_option(c('-i', '--min'), type='integer', default=3,
              help='min number of instances per bag [default = %default]', metavar = 'number'),
  make_option(c('-b', '--subSample'), type='integer', default=5000,
              help='maximum number of bags [default = %default]', metavar = 'number'),
  make_option(c('-l', '--ntotal'), type='integer', default=50000,
              help='ntotal [default = %default]', metavar = 'number'),
  make_option(c('-w', '--nwarm'), type='integer', default=25000,
              help='nwarm [default = %default]', metavar = 'number'),
  make_option(c('-n', '--nthin'), type='integer', default=10,
              help='nthin [default = %default]', metavar = 'number'),
  make_option(c('-c', '--nchain'), type='integer', default=3,
              help='nchain [default = %default]', metavar = 'number'),
  make_option(c('-e', '--nSample'), type='integer', default=50,
              help='number of samples from each chain to calculate beta/b pvals [default = %default]', metavar = 'number'),
  make_option(c("--generateCutoffs"), action="store_true", default=TRUE,
              help="Automatically generate cutoffs (default) or create plots for manual cutoff determination")
  
);

opt_parser = OptionParser(option_list=option_list);
opt = parse_args(opt_parser);

###########  parameters  ###########
cat('################starting run...################\n')
Sys.time()
if (is.null(opt$output)) {
  outFn = paste(opt$sendingCell, '-', opt$receivingCell, '_', opt$receivingGene)
} else{
  outFn = opt$output
}
isDir = F
if (substring(outFn,nchar(outFn)) == '/') {
  dir.create(outFn, showWarnings = FALSE, recursive = T)
  cat('output prefix is directory\n')
  isDir = T
} else{
  dir.create(dirname(outFn), showWarnings = FALSE, recursive = T)
}
run1 = F
if (is.null(opt$receivingGene)) {
  cat('no receiving gene provided\n')
  if (is.null(opt$paramTable)) {
    stop('*********terminating run: no csv provided for "-t"*********\n')
  }
  paramTable = fread(opt$paramTable, verbose = FALSE)
  recGenes = paramTable$gene_name
  cat('using receiving genes from cutoffs table\n')
  outFns = recGenes
  for (i in 1:length(outFns)) {
    if (isDir) {
      outFns[i] = paste(outFn, opt$sendingCell, '-', opt$receivingCell, '_', outFns[i], sep = '')
    } else{
      outFns[i] = paste(outFn, '_', opt$sendingCell, '-', opt$receivingCell, '_', outFns[i], sep = '')
    }
  }
} else{
  if (file.exists(opt$receivingGene)) {
    cat('reading receiving genes from file... \n')
    recGenes = read.table(opt$receivingGene)
    recGenes = recGenes$V1
  } else{
    run1 = T
    recGenes = c(opt$receivingGene)
    if (isDir) {
      outFns = c(paste(outFn, opt$sendingCell, '-', opt$receivingCell, '_', recGenes[1], sep = ''))
    } else{
      outFns = c(paste(outFn, '_', opt$sendingCell, '-', opt$receivingCell, '_', recGenes[1], sep = ''))
    }
  }
}



########### Load Cached Data  ###########
loadedCache = FALSE
if (dir.exists(outFn)) {
  cacheFn = file.path(outFn,
                      paste(opt$sendingCell,
                            '-',
                            opt$receivingCell,
                            '_cache.RData', sep = ''))
} else{
  cacheFn = file.path(dirname(outFn),
                      paste(opt$sendingCell,
                            '-',
                            opt$receivingCell,
                            '_cache.RData', sep = ''))
}
lockFn = paste(cacheFn, '.lock', sep = '')
noLock = TRUE
i = 0
while (noLock) {
  cacheLock = lock(lockFn, exclusive = T, timeout = 0)
  if (is.null(cacheLock)) {
    cat(paste('waiting for other process to write cache:', i*10, 's \n'))
    Sys.sleep(10)
  } else{
    noLock = FALSE
  }
}
if (file.exists(cacheFn)) {
  if (opt$overwrite) {
    cat('ignoring existing cache...\n')
  } else{
    Sys.time()
    unlock(cacheLock)
    if (file.exists(lockFn)) {
      unlink(lockFn)
    }
    cat(paste('loading from ', cacheFn, '...\n', sep = ''))
    load(cacheFn)
    cat('loaded...\n')
    loadedCache = TRUE
  }
}
# choose dataset, cell type pairs and genes to investigate
if (loadedCache) {
  tmpCheck = c(sending_cell_type != opt$sendingCell,
               receiving_cell_type != opt$receivingCell,
               # receiving_gene != opt$receivingGene,
               n_path != opt$path
  )
  if (any(tmpCheck)) {
    stop('*********terminating run: input mismatch with cache file; use -f to ignore cache*********\n')
  }
}



###########  Make Cache  ###########
if (!loadedCache) {
  sourceCpp(file.path(opt$spacia_path,"Fun_construct_bags.cpp"))
  
  sending_cell_type = opt$sendingCell
  cat(paste('sending cells:', sending_cell_type, '\n'))
  receiving_cell_type = opt$receivingCell
  cat(paste('receiving cells:', receiving_cell_type, '\n'))
  receiving_gene=opt$receivingGene
  cat(paste('receiving gene:', receiving_gene, '\n'))
  nSample = opt$nSample
  
  dist_cutoff=opt$dist
  cat(paste('distance cutoff:', dist_cutoff, '\n'))
  n_path=opt$path
  cat(paste('num. PCs:', n_path, '\n'))
  min_instance=opt$min
  cat(paste('min. instance/bag:', min_instance, '\n'))
  
  # other less important input parameters
  ntotal=opt$ntotal
  cat(paste('ntotal:', ntotal, '\n'))
  nwarm=opt$nwarm
  cat(paste('nwarm:', nwarm, '\n'))
  nthin=opt$nthin
  cat(paste('nthin:', nthin, '\n'))
  nchain=opt$nchain
  cat(paste('nchain:', nchain, '\n'))
  thetas=c(0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9)
  ########  read and pre-process data  ############
  Sys.time()
  cat('reading data...\n')
  options(scipen=999) 
  # do this in spacia
  meta=fread(opt$inputMeta, verbose = FALSE)
  counts=fread(opt$inputExpression, verbose = FALSE)
  Sys.time()
  cat('pre-processing data...\n')
  #process count data
  if (opt$isCount) {
    
    counts[, (2:ncol(counts)) := lapply(.SD, function(x) log1p(x / mean(x, na.rm = TRUE))), .SDcols = 2:ncol(counts)]
    
  }
  
  counts[, (names(counts)[-1]) := lapply(.SD, function(x) x / sd(x) * (sd(x) > 0)), .SDcols = -1]
  
  # Check for mismatches in cell names before alignment
  if (!all(meta[[1]] %in% counts[[1]])) {
    stop("Cell name mismatch!")
  }
  
  # Filter meta to get receivers and senders
  meta_receiver <- meta[cell_type == receiving_cell_type]
  meta_sender <- meta[cell_type == sending_cell_type]
  
  # Create subsets for receiver and sender cells in counts
  counts_receiver <- counts[counts[[1]] %in% meta_receiver[[1]]]
  counts_sender <- counts[counts[[1]] %in% meta_sender[[1]]]
  
  # Log information about the cell counts
  cat(paste('\treceiving cells:', nrow(meta_receiver), '\n'))
  cat(paste('\tsending cells:', nrow(meta_sender), '\n'))
  
  # Calculate PCA for sending cells without transposing the whole dataset
  Sys.time()
  cat('calculating pca...\n')
  pca_sender <- prcomp((counts_sender[, .SD, .SDcols = -1]))$x
  rownames(pca_sender)<-counts_sender[[1]]
  
  Sys.time()
  cat('processing pca...\n')
  pca_sender=t(t(pca_sender)/apply(pca_sender,2,sd))
  
  # Spatial data preparation for constructing bags
  Sys.time()
  cat('constructing bags...\n')
  xy_receiver <- as.matrix(meta_receiver[, .(X, Y)])
  xy_sender <- as.matrix(meta_sender[, .(X, Y)])
  
  # C++ optimized function
  results <- construct_bags(xy_receiver, xy_sender, meta_receiver[[1]], dist_cutoff^2, min_instance, opt$subSample)
  pos_sender <- results$pos_sender
  exp_sender <- results$exp_sender
  
  #construct bags names
  names_sender = list()
  for (x in names(exp_sender)) {
    names_sender[[x]] = counts_sender[,1][exp_sender[[x]]]
  }
  
  nbags = length(pos_sender)
  cat(paste("Total number of receiving cells:",dim(meta_receiver)[1],"\n"))
  cat(paste("Successfully constructed bags:",nbags,"\n"))
  Sys.time()
  cat(paste("saving cache file to ",cacheFn,"\n"))
  save(counts_receiver,counts_sender, pos_sender, exp_sender, pca_sender, names_sender,
       nbags, sending_cell_type, receiving_cell_type,  
       ntotal, nwarm, nthin, nchain, thetas, n_path, 
       file = cacheFn)
  unlock(cacheLock)
  if (file.exists(lockFn)) {
    unlink(lockFn)
  }
}

###########  Cutoff Plot Generation  ###########
runCutOff = FALSE
if (is.null(opt$quantile) & is.null(opt$corCut) & is.null(opt$paramTable)) {
  runCutOff = TRUE
}

if (runCutOff) {
  # Define output paths
  if (isDir) {
    outFns = sapply(recGenes, function(gene) paste(outFn, opt$sendingCell, '-', opt$receivingCell, '_', gene, sep = ''))
    cutoffPlotFolder = file.path(outFn, "cutoff_plots")
  } else {
    outFns = sapply(recGenes, function(gene) paste(outFn, '_', opt$sendingCell, '-', opt$receivingCell, '_', gene, sep = ''))
    cutoffPlotFolder = file.path(dirname(outFn), "cutoff_plots")
  }
  dir.create(cutoffPlotFolder, showWarnings = FALSE, recursive = TRUE)
  
  source(file.path(opt$spacia_path, "Automate_Cutoff_Spacia.R"))
  
  if (opt$generateCutoffs) {
    cat('Automatically generating cutoffs...\n')
    paramTable = data.frame(gene_name = character(), cor_cutoff = numeric(), quantile_cutoff = numeric())
    
    for (gene in recGenes) {
      result = AutomatedCutoffGenerator(gene, counts_receiver, cutoffPlotFolder, exp_sender)
      paramTable = rbind(paramTable, data.frame(gene_name = gene, 
                                                cor_cutoff = result$data$cor_cutoff, 
                                                quantile_cutoff = result$data$quantile))
      
      # # Save the plot with correct file path
      # plotFile = file.path(cutoffPlotFolder, paste0(gene, "_automated_cutoff.pdf"))
      # pdf(plotFile)
      # print(result$plot)
      # dev.off()
    }
    
    if (!run1) {
      # For multiple genes, save in the output directory
      paramTablePath = file.path(dirname(outFn), "paramTable.csv")
      write.csv(paramTable, file = paramTablePath, row.names = FALSE)
      cat('Generated paramTable saved to:', paramTablePath, '\n')
      opt$paramTable = paramTablePath  # Update opt$paramTable to use the new file
    } else {
      # For single gene run, save in cutoff_plots directory with specific naming
      paramTableName = paste0(opt$sendingCell, "-", opt$receivingCell, "_", recGenes[1], "_paramTable.csv")
      paramTablePath = file.path(cutoffPlotFolder, paramTableName)
      write.csv(paramTable, file = paramTablePath, row.names = FALSE)
      cat('Generated paramTable saved to:', paramTablePath, '\n')
      
      # Update opt values
      opt$quantile = paramTable$quantile_cutoff[1]
      opt$corCut = paramTable$cor_cutoff[1]
      cat('Single gene run: Updated quantile cutoff to', opt$quantile, 'and correlation cutoff to', opt$corCut, '\n')
    }
  } else {
    cat('Generating plots for manual cutoff determination...\n')
    for (gene in recGenes) {
      plotFile = file.path(cutoffPlotFolder, paste0(gene, "_cutoff_plot.pdf"))
      CutoffPlotGenerator(gene, counts_receiver, plotFile, exp_sender)
    }
    cat('Cutoff plots saved in:', cutoffPlotFolder, '\n')
    
    # Modified error handling for manual cutoff determination
    if (!run1) {
      if (is.null(opt$paramTable)) {
        stop('Cutoff plots generated. Please create paramTable.csv before proceeding with the analysis.')
      } else if (!file.exists(opt$paramTable)) {
        stop(paste('paramTable file not found at:', opt$paramTable))
      }
    } else {
      if (is.null(opt$quantile) || is.null(opt$corCut)) {
        stop('Cutoff plot generated. Please provide quantile and correlation cutoffs using -q and -u options before proceeding with the analysis.')
      }
    }
  }
}

loadCache = F

###########  Spacia for each receiving gene  ###########
for (mainI in 1:length(recGenes)) {
  receiving_gene = recGenes[mainI]
  outFn = outFns[mainI]
  cat(paste('running', sending_cell_type, 'to', receiving_cell_type, receiving_gene, '...\n'))
  cat(paste(mainI,'/',length(recGenes), '...\n', sep = ''))
  rDataFn = paste(outFn, '.RData', sep = '')
  lockFn1 = paste(rDataFn, '.lock', sep = '')
  runLock = lock(lockFn1, exclusive = T, timeout = 0)
  if (is.null(runLock)) {
    next
  }
  if (file.exists(rDataFn)) {
    if (opt$overwrite) {
      cat('overwriting existing output...\n')
    } else{
      Sys.time()
      cat(paste('found existing output', rDataFn, '...\n'))
      cat('*********skipped*********\n')
      unlock(runLock)
      if (file.exists(lockFn1)) {
        unlink(lockFn1)
      }
      next
    }
  }
  if (loadCache) {
    cat(paste('loading from ', cacheFn, '...\n', sep = ''))
    load(cacheFn)
    cat('loaded...\n')
  } else{
    loadCache = T
  }
  
  cat('finalizing spacia inputs...\n')
  # aggregate receiving genes to receiving pathways
  if (is.null(opt$paramTable)) {
    exp_receiver_quantile = opt$quantile
    cor_cutoff = opt$corCut
  } else{
    paramTable = fread(opt$paramTable, verbose = FALSE)
    tmp = paramTable[paramTable$gene_name == receiving_gene, ]
    if (dim(tmp)[1] == 1) {
      cor_cutoff = tmp$cor_cutoff
      exp_receiver_quantile = tmp$quantile_cutoff
      writeLines(paste('found ', receiving_gene, ':\n\tcor_cutoff: ', cor_cutoff, 
                       '\n\texp_receiver_quantile: ', exp_receiver_quantile, sep = ''))
    } else if (dim(tmp)[1] == 0){
      cat(paste('error:', receiving_gene, 'not found in table'))
      next
    }else if (dim(tmp)[1] > 1){
      cat(paste('error: multiple matches for', receiving_gene, 'found in table; check table'))
      next
    }
  }
  
  
  
  
  # Extract only numeric data excluding the first column for correlation calculation
  numeric_counts_receiver <- counts_receiver[, .SD, .SDcols = -1]
  
  # Ensure that the column names are correctly mapped to avoid including cell id in calculations
  if (!receiving_gene %in% names(numeric_counts_receiver)) {
    stop("Receiving gene not found in the data.")
  }
  
  cors <- cor(numeric_counts_receiver[[receiving_gene]], (numeric_counts_receiver))[1,]
  
  keep=abs(cors)>cor_cutoff
  if (sum(keep, na.rm = T) < 2) {
    
    cat(paste("no genes highly correlated with",receiving_gene,"\n"))
    next
  }
  cat(paste(sum(keep, na.rm = T),"genes highly correlated with",receiving_gene,"\n"))
  
  
  if (!all(names(exp_sender) %in% counts_receiver[[1]])) {
    stop("Column names in 'exp_sender' do not match 'counts_receiver'.")
  }
  
  
  
  counts_receiver_filtered <- counts_receiver[counts_receiver[[1]] %in% names(exp_sender)]
  numeric_counts_receiver_filtered <- counts_receiver_filtered[, .SD, .SDcols = -1]
  numeric_counts_receiver_filtered <- numeric_counts_receiver_filtered[, ..keep]
  
  cors_filtered <- cors[keep] 
  
  # Using set() for an efficient in-place modification
  for (j in seq_along(cors_filtered)) {
    set(numeric_counts_receiver_filtered, j = j, value = numeric_counts_receiver_filtered[[j]] * cors_filtered[j])
  }
  
  signature <- rowMeans(numeric_counts_receiver_filtered, na.rm = TRUE)
  names(signature) <- names(exp_sender)
  
  exp_receiver <- as.integer(signature > quantile(signature, exp_receiver_quantile, na.rm = TRUE))
  
  
  # # users may want to do some trial and errors to choose the tuning parameters 
  # # for a good "exp_receiver" 
  # maxBags = opt$subSample
  # if (maxBags > 0) {
  #   if (nbags > maxBags) {
  #     cat(paste("Subsampling constructed bags to",maxBags,"\n"))
  #     keep1 = sample(1:length(exp_receiver), maxBags)
  #     exp_receiver = exp_receiver[keep1]
  #     pos_sender = pos_sender[keep1]
  #     exp_sender = exp_sender[keep1]
  #   }
  # }
  #reconstruct exp_sender from index
  for (x in names(exp_sender)) {
    exp_sender[[x]] = pca_sender[exp_sender[[x]],1:n_path]
  }
  Sys.time()
  
  ######  run spacia  #####################
  cat('loading spacia...\n')
  #path for required libraries for spacia (edit if needed)
  #Sys.setenv(LIBRARY_PATH = "/cm/shared/apps/intel/compilers_and_libraries/2017.6.256/linux/mkl/lib/intel64:/cm/shared/apps/java/oracle/jdk1.7.0_51/lib:/cm/shared/apps/intel/compilers_and_libraries/2017.6.256/linux/compiler/lib/intel64:/cm/shared/apps/intel/compilers_and_libraries/2017.6.256/linux/mpi/intel64/lib:/cm/shared/apps/openmpi/gcc/64/2.1.5/lib64:/cm/shared/apps/gcc/5.4.0/lib:/cm/shared/apps/gcc/5.4.0/lib64:/cm/shared/apps/slurm/16.05.8/lib64/slurm:/cm/shared/apps/slurm/16.05.8/lib64")
  spacia_path = opt$spacia_path
  sourceCpp(file.path(spacia_path,"Fun_MICProB_C2Cinter.cpp"))
  source(file.path(spacia_path,'MICProB_MIL_C2Cinter.R'))
  source(file.path(spacia_path,'MIL_wrapper.R'))
  
  cat('running spacia...\n')
  Sys.time()
  results=MIL_C2Cinter(exp_receiver,pos_sender,exp_sender,
                       ntotal,nwarm,nthin,nchain,thetas, 1)
  Sys.time()
  
  cat('processing results...\n')
  # important:
  # rotation: the contribution of each sending gene expression to each PC
  # beta: the contribution of each PC to receiving gene expression
  # sum(rotation*beta): the contribution of each sending gene to each receiving gene
  rotation=prcomp((counts_sender[, .SD, .SDcols = -1]))$rotation
  # we have many beta values from multiple MCMC iterations
  # instead of using mean(beta) and multiple with rotation
  # we multiply each beta with rotation and then sum. Then
  # these sums will form a distribution from which we can do stat test
  gene_level_beta=results$beta %*% t(rotation[,1:dim(results$beta)[2]])
  
  #####  examine results  ########
  # check top genes with the largest/smallest gene-level beta
  # tmp=colMeans(gene_level_beta)
  # cat('top 10 gene betas')
  # tmp[rank(-abs(tmp))<10]
  
  # needs to be negative to make sense
  cat(paste('mean b: ', mean(results$b), ' \n', sep = ''))
  
  Sys.time()
  cat('saving raw results... \n')
  
  save(gene_level_beta, results, nbags, exp_receiver,pos_sender,exp_sender,names_sender,
       sending_cell_type , receiving_cell_type, receiving_gene,
       file = rDataFn)
  cat(paste('saved results to', rDataFn, '\n'))
  cat('saving csv results... \n')
  
  ######  process spacia outputs  #####################
  #recover order from structure of input 
  #EX:
  #	{receivingCell1: {sendingCell1: val, sendingCell2: val...}, 
  #  receivingCell2: {sendingCell1: val, sendingCell3: val...}, ...}
  #
  options(scipen=999)
  sendL = c()
  recL = c()
  for (receiver in names(names_sender)) {
    tmp = names_sender[[receiver]]$V1
    recL = c(recL, rep(receiver, length(tmp)))
    sendL = c(sendL, tmp)
  }
  
  #sample nSample of each MCMC chain to calculate beta/b pvals
  ##check results
  nOutPerChain = (ntotal - nwarm) / nthin + 1
  nOutExpected = nOutPerChain * nchain
  
  nBeta = dim(gene_level_beta)[1]
  if (nBeta != nOutExpected) {
    stop(paste('error:', basename(outFn), 'contains', nBeta, 'betas', nOutExpected, 'expected.'))
  }
  nB = dim(results$b)[1]
  if (nB != nOutExpected) {
    stop(paste('error:', basename(outFn), 'contains', nB, "b's", nOutExpected, 'expected.'))
  }
  ##get pvals
  betas0 = c()
  bs = c()
  ind = 0
  ii = c()
  for (n in 1:nchain) {
    i = 1
    offsetI = (n -1) * nOutPerChain
    inds = round(seq.int(i + offsetI, nOutPerChain + offsetI, length.out = 50))
    ii = c(ii, inds)
    betas0 = rbind(betas0, gene_level_beta[inds,])
    bs = c(bs,results$b[inds, 2])
  }
  ###one sided t-test for b (expect b < 0 for true interactions)
  testRes = t.test(bs, alternative = 'less')
  bPval = testRes$p.value
  ###two sided t-test for beta
  testRes = apply(betas0, 2, function(x){res = t.test(x); res$p.value})
  testFdr = p.adjust(testRes, method="BH")
  betas = data.frame('sending_gene' = names(testRes),
                     'receiving_gene' = receiving_gene,
                     'avg_beta' = colMeans(gene_level_beta),
                     'avg_beta_sampled' = colMeans(betas0),
                     "beta_pval" = testRes,
                     "beta_FDR" = testFdr,
                     'b' = colMeans(results$b)[2],
                     "b_sampled" = mean(bs),
                     "b_pval" = bPval)
  df = data.frame('receiving_cell' = recL,
                  'sending_cell' = sendL, 
                  'receiving_gene' = rep(receiving_gene, length(sendL)),
                  'avg_primary_instance_score' = rowMeans(results$pip)) #each col is from one mcmc chain
  save(gene_level_beta, results, nbags, exp_receiver,pos_sender,exp_sender,names_sender,
       ii, betas0, bs, file = rDataFn)
  write.csv(betas, file = paste(outFn, '_betas.csv', sep = ''), quote = FALSE, row.names = FALSE)
  write.csv(df, file = paste(outFn, '_pip.csv', sep = ''), quote = FALSE, row.names = FALSE)
  
  # Convert the list of data frames to JSON
  json_data <- toJSON(names_sender, pretty = TRUE)
  
  # Write the JSON to a file
  write(json_data, paste(outFn,"names_sender.json", sep = ''))
  
  cat('saved csv results\n')
  Sys.time()
  # if (file.exists(cacheFn)) {
  #   unlink(cacheFn)
  # }
  unlock(runLock)
  unlink(lockFn1)
  cat(paste('######finished ', receiving_gene, '######\n\n\n', sep = ''))
  if (run1) {
    break
  }
}

