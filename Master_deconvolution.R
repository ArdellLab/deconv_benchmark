args <- commandArgs(trailingOnly=TRUE)

if(length(args)!=9){

  	print("Please check that all required parameters are indicated or are correct")
  	print("Example usage for bulk deconvolution methods: 'Rscript Master_deconvolution.R baron none bulk TMM all nnls 100 none 1'")
  	print("Example usage for single-cell deconvolution methods: 'Rscript Master_deconvolution.R baron none sc TMM TMM MuSiC 100 none 1'")
  	stop()
} 

### arguments
dataset = args[1]
transformation = args[2]
deconv_type = args[3]

if(deconv_type == "bulk"){
	normalization = args[4]
	marker_strategy = args[5]
} else if (deconv_type == "sc") {
	normalization_scC = args[4]
	normalization_scT = args[5]
} else {
	print("Please enter a valid deconvolution framework")
	stop()
}

method = args[6]
number_cells = round(as.numeric(args[7]), digits = -2) #has to be multiple of 100
to_remove = args[8]
num_cores = min(as.numeric(args[9]),parallel::detectCores()-1)

#-------------------------------------------------------
### Helper functions + CIBERSORT external code
source('./helper_functions.R')
# source('CIBERSORT.R')

#-------------------------------------------------------
### Read data and metadata
data = readRDS(list.files(path = dataset, pattern = "rds", full.names = TRUE))
full_phenoData = read.table(list.files(path = dataset, pattern = "phenoData", full.names = TRUE), header=TRUE)

#-------------------------------------------------------
### QC 
require(dplyr); require(Matrix)

# First: cells with library size, mitochondrial or ribosomal content further than three MAD away were discarded
filterCells <- function(filterParam){
	cellsToRemove <- which(filterParam > median(filterParam) + 3 * mad(filterParam) | filterParam < median(filterParam) - 3 * mad(filterParam) )
	cellsToRemove
}

libSizes <- colSums(data)
gene_names <- rownames(data)

mtID <- grepl("^MT-|_MT-", gene_names, ignore.case = TRUE)
rbID <- grepl("^RPL|^RPS|_RPL|_RPS", gene_names, ignore.case = TRUE)

mtPercent <- colSums(data[mtID, ])/libSizes
rbPercent <- colSums(data[rbID, ])/libSizes

lapply(list(libSizes = libSizes, mtPercent = mtPercent, rbPercent = rbPercent), filterCells) %>% 
	unlist() %>% 
	unique() -> cellsToRemove

if(length(cellsToRemove) != 0){
	data <- data[,-cellsToRemove]
	full_phenoData <- full_phenoData[-cellsToRemove,]
}

# Keep only "detectable" genes: at least 5% of cells (regardless of the group) have a read/UMI count different from 0
keep <- which(Matrix::rowSums(data > 0) >= round(0.05 * ncol(data)))
data = data[keep,]

#-------------------------------------------------------
### Data split into training/test 
set.seed(24)
require(limma); require(dplyr); require(pheatmap)

original_cell_names = colnames(data)
colnames(data) <- as.character(full_phenoData$cellType[match(colnames(data),full_phenoData$cellID)])

# Keep CTs with >= 50 cells after QC
cell_counts = table(colnames(data))
to_keep = names(cell_counts)[cell_counts >= 50]
pData <- full_phenoData[full_phenoData$cellType %in% to_keep,]
to_keep = which(colnames(data) %in% to_keep)   
data <- data[,to_keep]
original_cell_names <- original_cell_names[to_keep]


# Data split into train & test  
training <- as.numeric(unlist(sapply(unique(colnames(data)), function(x) {
            sample(which(colnames(data) %in% x), cell_counts[x]/2) })))
testing <- which(!1:ncol(data) %in% training)

# Generate phenodata for reference matrix C
pDataC = pData[training,]

train <- data[,training]
test <- data[,testing]

# "write.table" & "saveRDS" statements are optional, for users willing to avoid generation of matrix C every time:    
# write.table(pDataC, file = paste(dataset,"phenoDataC",sep="_"),row.names=FALSE,col.names=TRUE,sep="\t",quote=FALSE)

train_cellID = train
colnames(train_cellID) = original_cell_names[training]
# saveRDS(object = train_cellID, file = paste(dataset,"qc_filtered_train.rds",sep="_")) #It has to contain cellID as colnames, not cellType (for scRNA-seq methods)
# saveRDS(object = test, file = paste(dataset,"qc_filtered_test.rds",sep="_"))

# reference matrix (C) + refProfiles.var from TRAINING dataset
cellType <- colnames(train)
group = list()
for(i in unique(cellType)){ 
	group[[i]] <- which(cellType %in% i)
}
C = lapply(group,function(x) Matrix::rowMeans(train[,x])) #C should be made with the mean (not sum) to agree with the way markers were selected
C = round(do.call(cbind.data.frame, C))
# write.table(C, file = "C",row.names=TRUE,col.names=TRUE,sep="\t",quote=FALSE,)

refProfiles.var = lapply(group,function(x) train[,x])
refProfiles.var = lapply(refProfiles.var, function(x) matrixStats::rowSds(Matrix::as.matrix(x)))
refProfiles.var = round(do.call(cbind.data.frame, refProfiles.var))
rownames(refProfiles.var) <- rownames(train)
# write.table(refProfiles.var, "refProfiles.var", quote=FALSE,row.names=TRUE,col.names=TRUE,sep="\t")

#-------------------------------------------------------
#Normalization of "train" followed by marker selection 

#for marker selection, keep genes where at least 30% of cells within a cell type have a read/UMI count different from 0
cellType = colnames(train) 
keep <- sapply(unique(cellType), function(x) {
	CT_hits = which(cellType %in% x)
 	size = ceiling(0.3*length(CT_hits))
 	Matrix::rowSums(train[,CT_hits,drop=FALSE] != 0) >= size
})
train = train[Matrix::rowSums(keep) > 0,]
train2 = Normalization(train)

# INITIAL CONTRASTS for marker selection WITHOUT taking correlated CT into account 
#[compare one group with average expression of all other groups]
annotation = factor(colnames(train2))
design <- model.matrix(~0+annotation)
colnames(design) <- unlist(lapply(strsplit(colnames(design),"annotation"), function(x) x[2]))
cont.matrix <- matrix((-1/ncol(design)),nrow=ncol(design),ncol=ncol(design))
colnames(cont.matrix) <- colnames(design)
diag(cont.matrix) <- (ncol(design)-1)/ncol(design)

v <- limma::voom(train2, design=design, plot=FALSE) 
fit <- limma::lmFit(v, design)
fit2 <- limma::contrasts.fit(fit, cont.matrix)
fit2 <- limma::eBayes(fit2, trend=TRUE)

markers = marker.fc(fit2, log2.threshold = log2(2))

#-------------------------------------------------------
### Generation of 1000 pseudo-bulk mixtures (T) (on test data)
cellType <- colnames(test)
colnames(test) <- original_cell_names[testing]

generator <- Generator(sce = test, phenoData = full_phenoData, Num.mixtures = 1000, pool.size = number_cells)
T <- generator[["T"]]
P <- generator[["P"]]

#-------------------------------------------------------
### Transformation, scaling/normalization, marker selection for bulk deconvolution methods and deconvolution:
if(deconv_type == "bulk"){

	T = Transformation(T, transformation)
	C = Transformation(C, transformation)

	T = Scaling(T, normalization)
	C = Scaling(C, normalization)

	# marker selection (on training data) 
	marker_distrib = marker_strategies(markers, marker_strategy, C)

	#If a cell type is removed, only meaningful mixtures where that CT was present (proportion < 0) are kept:
	if(to_remove != "none"){

		T <- T[,P[to_remove,] != 0]
		C <- C[, colnames(C) %in% rownames(P) & (!colnames(C) %in% to_remove)]
		P <- P[!rownames(P) %in% to_remove, colnames(T)]
		refProfiles.var = refProfiles.var[,colnames(refProfiles.var) %in% rownames(P) & (!colnames(refProfiles.var) %in% to_remove)]
		marker_distrib <- marker_distrib[marker_distrib$CT %in% rownames(P) & (marker_distrib$CT != to_remove),]
		
	}

	RESULTS = Deconvolution(T = T, C = C, method = method, P = P, elem = to_remove, marker_distrib = marker_distrib, refProfiles.var = refProfiles.var) 

} else if (deconv_type == "sc"){

	T = Transformation(T, transformation)
	C = Transformation(train_cellID, transformation)

	T = Scaling(T, normalization_scT)
	C = Scaling(C, normalization_scC)

	#If a cell type is removed, only meaningful mixtures where that CT was present (proportion < 0) are kept:
	if(to_remove != "none"){

		T <- T[,P[to_remove,] != 0]
		C <- C[,pDataC$cellType != to_remove]
		P <- P[!rownames(P) %in% to_remove, colnames(T)]
		pDataC <- pDataC[pDataC$cellType != to_remove,]

	}

	RESULTS = Deconvolution(T = T, C = C, method = method, phenoDataC = pDataC, P = P, elem = to_remove, refProfiles.var = refProfiles.var) 

}

RESULTS = RESULTS %>% dplyr::summarise(RMSE = sqrt(mean((observed_values-expected_values)^2)) %>% round(.,4), 
									   Pearson=cor(observed_values,expected_values) %>% round(.,4))
print(RESULTS)