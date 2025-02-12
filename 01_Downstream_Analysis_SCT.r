suppressPackageStartupMessages({
library(tidyverse)
library(ggrepel)
library(emmeans)
library(SingleCellExperiment)
library(scater)
library(BiocParallel)
library(ggpubr)
library(speckle)
library(magrittr)
library(broom)
library(muscat)
library(Seurat)
library(clustree)
library(leiden)
library(data.table)
library(cowplot)
library(scDblFinder)
library(BiocSingular)
})
source("utils/Utils.R")

#plan("multiprocess", workers = 10)
options(future.globals.maxSize = 6000 * 1024^2)

dir.create("output_initial")

#load protein coding genes
load("utils/MgProteinCodingGenes.rda")

SalineCPP <- Read10X_h5("input/5107-MR-85/CellBender_out_filtered.h5", use.names = TRUE, unique.features = TRUE)
CocaineCPP <- Read10X_h5("input/5107-MR-86/CellBender_out_filtered.h5", use.names = TRUE, unique.features = TRUE)
SalineNPAS4 <- Read10X_h5("input/5107-MR-87/CellBender_out_filtered.h5", use.names = TRUE, unique.features = TRUE)
CocaineNPAS4 <- Read10X_h5("input/5107-MR-88/CellBender_out_filtered.h5", use.names = TRUE, unique.features = TRUE)

SalineCPP <- SalineCPP[rownames(SalineCPP)%in%MgProteinCodingGenes,]
CocaineCPP <- CocaineCPP[rownames(CocaineCPP)%in%MgProteinCodingGenes,]
SalineNPAS4 <- SalineNPAS4[rownames(SalineNPAS4)%in%MgProteinCodingGenes,]
CocaineNPAS4 <- CocaineNPAS4[rownames(CocaineNPAS4)%in%MgProteinCodingGenes,]

SalineCPP_obj <- CreateSeuratObject(counts = SalineCPP,min.features = 100)
CocaineCPP_obj <- CreateSeuratObject(counts = CocaineCPP,min.features = 100)
SalineNPAS4_obj <- CreateSeuratObject(counts = SalineNPAS4,min.features = 100)
CocaineNPAS4_obj <- CreateSeuratObject(counts = CocaineNPAS4,min.features = 100)

seuObject <- merge(SalineCPP_obj, 
                  y = c(CocaineCPP_obj,SalineNPAS4_obj,CocaineNPAS4_obj), 
                  add.cell.ids = c("SalineCPP", "CocaineCPP","SalineNPAS4","CocaineNPAS4"), 
                  project = "Brandon")

seuObject[["pMito"]] <- PercentageFeatureSet(seuObject, pattern = "^mt-")


seuObject@meta.data <- seuObject@meta.data %>%
						rownames_to_column("Cell") %>%
						mutate(Genotype = sapply(X = strsplit(colnames(seuObject), split = "_"), FUN = "[", 1)) %>%
			        	dplyr::rename(nUMI = nCount_RNA, nGene = nFeature_RNA) %>%
			        	column_to_rownames("Cell")

save(seuObject,file="output_initial/Brandon_SeuratObj_Unfilt.RData")
rm(SalineCPP_obj,CocaineCPP_obj,SalineNPAS4_obj,CocaineNPAS4_obj,SalineCPP,CocaineCPP,SalineNPAS4,CocaineNPAS4)

# Check
pdf("output_initial/Quality_Control_plots.pdf", width=6,height=4)
feats <- c("nUMI", "nGene", "pMito")
VlnPlot(seuObject, group.by = "Genotype", features = feats, pt.size = 0, ncol = 3) + 
    NoLegend()
dev.off()

pdf("output_initial/Quality_Control_Scatter.pdf", width=5,height=4)
FeatureScatter(seuObject, "nUMI", "nGene", group.by = "Genotype", pt.size = 0)
dev.off()

#pdf("output/UMIvsGene.pdf", width=5,height=4)
#ggplot(seuObject@meta.data, aes(x=nUMI, y=nGene, color=Genotype)) +
#ggrastr::geom_point_rast(size=0.5) + 
#theme_classic()
#dev.off()

#pdf("output/pMitoVsUMI.pdf", width=5,height=4)
#ggplot(seuObject@meta.data, aes(x=nUMI, y=pMito, color=Genotype)) +
#ggrastr::geom_point_rast(size=0.5) + 
#theme_classic()
#dev.off()

# Visualize the correlation between genes detected and number of UMIs. D
# Determine whether strong presence of cells with low numbers of genes/UMIs
scatter <- seuObject@meta.data %>% 
  	ggplot(aes(x=nUMI, y=nGene, color=pMito)) + 
  	geom_point() + 
	scale_colour_gradient(low = "gray90", high = "black") +
  	stat_smooth(method=lm) +
  	scale_x_log10() + 
  	scale_y_log10() + 
  	theme_classic() +
  	geom_vline(xintercept = 500) +
  	geom_hline(yintercept = 250) +
  	facet_wrap(~Genotype)
ggsave("output_initial/GeneXUMI.pdf", plot = scatter, width = 6, height = 4, units = "in", dpi = 150)


##-------------------------------------------------------
## DATA FILTERING
##-------------------------------------------------------

#####################
## Remove MT genes ##
#####################


mito_filtered <- seuObject@assays$RNA@counts[-grep("^mt-",rownames(seuObject@assays$RNA@counts)),]

# Initialize the Seurat object with the raw (non-normalized data).
seuObject_final <- CreateSeuratObject(counts = mito_filtered, project = "Brandon")

## Add pMito info from meta data for all cells before filtering
metaAll <- as.data.frame(seuObject@meta.data)
seuObject_final <- AddMetaData(object = seuObject_final, metadata = as.data.frame(seuObject@meta.data))
seuObject_final@meta.data$nCount_RNA <- NULL
seuObject_final@meta.data$nFeature_RNA <- NULL

seuObject_filt <- subset(x = seuObject_final, subset = nUMI < 10000 & pMito < 5 & nUMI > 1000 & nGene > 250)

save(seuObject_filt,file="output_initial/Brandon_SeuratObj_Filt.RData")
rm(seuObject,seuObject_final)


# Data Integration

seuObject_split <- SplitObject(seuObject_filt, split.by = "Genotype")

seuObject_split <- seuObject_split[c("SalineCPP", "CocaineCPP","SalineNPAS4","CocaineNPAS4")]

for (i in 1:length(seuObject_split)) {
    seuObject_split[[i]] <- SCTransform(seuObject_split[[i]], 
				    						vars.to.regress = c("nUMI","pMito"), 
											verbose = FALSE)
    }

integ_features <- SelectIntegrationFeatures(object.list = seuObject_split, 
											nfeatures = 4000) 

seuObject_split <- PrepSCTIntegration(object.list = seuObject_split, 
											anchor.features = integ_features)

integ_anchors <- FindIntegrationAnchors(object.list = seuObject_split, 
                                        normalization.method = "SCT", 
                                        anchor.features = integ_features)

seuObject_integrated <- IntegrateData(
								anchorset = integ_anchors,
								new.assay.name = "integrated",
								normalization.method = "SCT",
								dims = 1:30,
								k.weight = 100,
								sd.weight = 1,
								eps = 0.5,
								verbose = TRUE
								)

DefaultAssay(seuObject_integrated) <- "integrated"

seuObject_integrated <- RunPCA(object = seuObject_integrated, 
								features=NULL, 
								weight.by.var = TRUE, 
								ndims.print = 1:5, 
								nfeatures.print = 30, 
								npcs = 30, 
								reduction.name = "pca")

seuObject_integrated <- FindNeighbors(object = seuObject_integrated, 
										reduction = "pca", 
										dims = 1:30, 
										nn.eps = 0.5)

seuObject_integrated <- FindClusters(object = seuObject_integrated, 
										resolution = c(0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2), 
										algorithm = 1,
										n.iter = 1000)

pdf("output/Data_Integrated_Clustree.pdf", width = 12, height = 6)
clustree(seuObject_integrated@meta.data, prefix = "integrated_snn_res.", node_colour = "sc3_stability")
dev.off()

# Select resolution and run UMAP
Idents(object = seuObject_integrated) <- "integrated_snn_res.0.5"

seuObject_integrated <- RunUMAP(object = seuObject_integrated, 
										reduction = "pca", 
										dims = 1:30)

# Select the RNA counts slot to be the default assay
DefaultAssay(seuObject_integrated) <- "RNA"
seuObject_integrated <- NormalizeData(object = seuObject_integrated, 
						normalization.method = "LogNormalize", 
						scale.factor = 10000)


seuObject_integrated@meta.data <- seuObject_integrated@meta.data %>%
                                       rownames_to_column("TMP") %>%
                                       select(TMP,orig.ident,Genotype,pMito,nCount_SCT,nFeature_SCT,integrated_snn_res.0.6) %>%
                                       column_to_rownames("TMP")

save(seuObject_integrated, file = "output_initial/Brandon_SeuratObj_SCT_30pcs_05res.RData")

# 
pdf("output_initial/Data_Integrated_UMAP.pdf", width = 10, height = 6)
p1 <- DimPlot(object = seuObject_integrated, reduction = "umap", label = TRUE, pt.size = 0.5) + theme(legend.position="none")
p2 <- DimPlot(object = seuObject_integrated, reduction = "umap", label = FALSE, pt.size = 0.5, group.by="Genotype")
plot_grid(p1, p2)
dev.off()

seuObject_integrated_slim <- DietSeurat(seuObject_integrated, 
										counts = TRUE, 
										data = TRUE, 
										scale.data = FALSE,
										assays="RNA",
										dimreducs = c("pca","umap"))

save(seuObject_integrated_slim, file = "output_initial/Brandon_SeuratObj_SCT_30pcs_05res_Slimmed.RData")
