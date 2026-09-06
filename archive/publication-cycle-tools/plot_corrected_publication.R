args <- commandArgs(TRUE)
out <- args[1]
pkg <- args[2]
rd <- function(name) read.csv(file.path(out, name), check.names = FALSE)
cols <- c('#0072B2', '#D55E00', '#009E73', '#CC79A7')
start <- function(name, width=2100, height=2000) {
    png(file.path(out,name), width=width, height=height, res=230)
    par(family='sans', cex=.9, las=1)
}
heat <- function(z, title, labels, logscale=FALSE) {
    nr <- nrow(z); nc <- ncol(z)
    par(mar=c(3.5,10,2,1))
    value <- if(logscale) log10(pmax(z,1e-6)) else z
    palette <- colorRampPalette(c('#FFFFFF','#9ECAE1'))(40)
    image(seq_len(nc),seq_len(nr),t(value[nr:1,,drop=FALSE]), col=palette,
          axes=FALSE,xlab='',ylab='',main=title)
    axis(1,seq_len(nc),colnames(z),cex.axis=.6)
    axis(2,seq_len(nr),rev(labels),cex.axis=.62,tick=FALSE)
    for(i in seq_len(nr)) for(j in seq_len(nc)) {
        v <- z[i,j]; txt <- if(is.na(v)) 'Not measured' else format(signif(v,3),trim=TRUE)
        text(j,nr-i+1,txt,cex=.63)
    }
}
r <- rd('r_panel.csv'); ds <- unique(r$dataset); methods <- unique(r$method_id)
short <- gsub('fastPLS_simpls_cpu_irlba','fastPLS iterative reference',methods)
short <- gsub('fastPLS_simpls_lda','fastPLS reference / LDA',short)
short <- gsub('_',' ',short)
start('figure1.png',2300,2600);layout(matrix(1:4,4,1),heights=c(1,1,1,.8))
for(field in c('median_metric','median_time_ms','median_peak_host_rss_mb')) {
    z <- matrix(NA_real_,length(methods),length(ds),dimnames=list(methods,ds))
    for(i in seq_len(nrow(r)))z[r$method_id[i],r$dataset[i]] <- r[[field]][i]/if(field=='median_time_ms')1000 else 1
    heat(z,switch(field,median_metric='A1  Independent R workflows: accuracy',median_time_ms='A2  Total time (seconds)',median_peak_host_rss_mb='A3  Absolute process RSS (MiB)'),short,field!='median_metric')
}
g <- rd('gpu_ikpls.csv');par(mar=c(3,10,2,1))
labs <- paste(g$method,g$call);labs <- gsub('IKPLS_jax_cuda_alg1','IKPLS score-explicit',labs);labs <- gsub('IKPLS_jax_cuda_alg2','IKPLS cross-product',labs)
b <- barplot(g$time,horiz=TRUE,names.arg=labs,col=c(cols[1],rep(cols[2],4)),cex.names=.7,xlim=c(0,max(g$time)*1.3),main='B  Separate CIFAR-100 GPU comparison, 50 components',xlab='Seconds')
text(g$time,b,labels=paste0(format(round(g$time,3),nsmall=3),' s'),pos=4,cex=.75);dev.off()

start('figure2.png',2300,1500);par(mfrow=c(1,2))
for(file in c('cuda_selected.csv','metal_selected.csv')) {
    a <- rd(file); gpu <- if(grepl('cuda',file)) 'cuda' else 'metal'
    ds <- unique(a$dataset); fam <- c('plssvd','simpls','opls','kernelpls')
    z <- matrix(NA_real_,length(ds),4,dimnames=list(ds,c('PLS-SVD','SIMPLS','OPLS','Kernel PLS')))
    for(i in seq_along(ds))for(j in seq_along(fam)) {
        sub <- a[a$dataset==ds[i]&a$method==fam[j],]
        c <- sub[sub$backend=='cpu',];u <- sub[sub$backend==gpu,]
        if(nrow(c)==1&&nrow(u)==1&&c$ncomp==u$ncomp)z[i,j] <- c$median_total_sec/u$median_total_sec
    }
    heat(z,paste('CPU /',toupper(gpu),'runtime ratio'),ds,TRUE)
}
dev.off()

n <- rd('nmr_merged_plot_values.csv');d <- rd('deposited_reference.csv')
n <- n[n$backend=='metal'&n$precision=='float64'&n$ncomp==165,]
n <- n[match(c('plssvd','simpls'),n$family),]
time <- c(d$total_time_sec,n$median_total_sec);err <- c(d$RMSD,n$median_RMSD)
mem <- c(d$incremental_peak_rss_mib,n$median_incremental_rss_mib)
labs <- c('Deposited CPU','PLS-SVD Metal','SIMPLS Metal')
z <- readRDS(file.path(pkg,'publication_results/0.99.39/current_release/nmr/fixed165_simpls_cuda_rsvd_k165_prediction.rds'))
idx <- which.min(abs(z$per_sample_rmsd-median(z$per_sample_rmsd)))
ppm <- as.numeric(colnames(z$observed))
write.csv(data.frame(sample_index=idx,sample_id=rownames(z$observed)[idx],rule='nearest median saved CUDA per-spectrum RMSD'),file.path(out,'spectrum_selection.csv'),row.names=FALSE)
start('figure3.png',2300,2400);par(mfrow=c(3,2),mar=c(4.5,5,2.5,1))
for(q in list(list(time,'A  165-component total time','Seconds (log scale)'),list(err,'B  165-component RMSD','RMSD'),list(mem,'C  Incremental process RSS','MiB'))) {
    log <- if(q[[2]]=='A  165-component total time') 'y' else ''
    b <- barplot(q[[1]],names.arg=labs,col=cols[1:3],cex.names=.65,log=log,main=q[[2]],ylab=q[[3]],ylim=c(if(log=='y').5 else 0,max(q[[1]])*1.4))
    text(b,q[[1]],signif(q[[1]],3),pos=3,cex=.7)
}
boxplot(z$per_sample_rmsd,col=cols[1],ylab='RMSD',main='D  Saved CUDA per-spectrum error',names='321 held-out spectra')
for(range in list(c(12,0),c(1.7,.5))) {
    keep <- ppm<=max(range)&ppm>=min(range)
    yr <- range(c(z$observed[idx,keep],z$predicted[idx,keep]),finite=TRUE)
    plot(ppm,z$observed[idx,],type='l',col='black',xlim=range,ylim=yr,xlab='Chemical shift (ppm)',ylab='Spectral intensity',main=if(range[1]==12)'E  Full spectrum' else 'F  Spectral detail',lwd=1)
    lines(ppm,z$predicted[idx,],col=cols[1],lwd=.8)
    legend('topright',c('Observed','Predicted'),col=c('black',cols[1]),lty=1,bty='n',cex=.7)
}
dev.off()

im <- rd('imagenet_plot_values.csv');heads <- unique(im$classifier)
start('figure4.png',2300,1900);layout(matrix(c(1,1,2,3),2,2))
par(mar=c(4,4,3,1));plot(range(im$ncomp_requested),range(c(im$top1_accuracy,im$top5_accuracy)),type='n',xlab='Components',ylab='Accuracy',main='A  ImageNet: later hybrid float32 prefix path')
for(i in seq_along(heads)){s <- im[im$classifier==heads[i],];lines(s$ncomp_requested,s$top1_accuracy,type='b',col=cols[i],pch=16);lines(s$ncomp_requested,s$top5_accuracy,type='b',col=cols[i],lty=2,pch=1)}
legend('bottomright',c('Argmax top-1','Argmax top-5','LDA top-1','LDA top-5'),col=rep(cols[1:2],each=2),lty=rep(1:2,2),bty='n',cex=.85)
one <- im[!duplicated(im$classifier),]
par(mar=c(4,4,3,1));b <- barplot(one$total_time_sec,names.arg=one$classifier,col=cols[1:2],main='B  Whole model and prefix path',ylab='Seconds',ylim=c(0,max(one$total_time_sec)*1.2));text(b,one$total_time_sec,round(one$total_time_sec,1),pos=3)
barplot(rbind(one$process_peak_rss_mb,one$gpu_peak_mb),beside=TRUE,names.arg=one$classifier,col=cols[1:2],main='C  Absolute peak memory',ylab='MiB',legend.text=c('Host process','Device'))
dev.off()

s <- rd('nmr_selection.csv');start('figureS2.png',2100,1300);par(mfrow=c(1,2),mar=c(4,4,3,1))
for(fam in c('plssvd','simpls')) {
    a <- s[s$family==fam,];plot(a$ncomp,a$RMSD_mean,type='b',pch=16,col=cols[1],xlab='Components',ylab='Mean validation RMSD',main=toupper(fam))
    arrows(a$ncomp,a$RMSD_mean-a$RMSD_se,a$ncomp,a$RMSD_mean+a$RMSD_se,angle=90,code=3,length=.02,col=cols[1])
    b <- which.min(a$RMSD_mean);abline(h=a$RMSD_mean[b]+a$RMSD_se[b],lty=2)
    abline(v=if(fam=='plssvd')75 else 50,lty=3,col=cols[2])
}
dev.off()
cp <- rd('component_paths.csv');ds <- unique(cp$dataset)
start('figureS1.png',2400,2600);par(mfrow=c(4,3),mar=c(3,3.5,2,1),cex=.8)
for(dataset in ds) {
    a <- cp[cp$dataset==dataset,];plot(range(a$ncomp),range(a$median_total_sec),type='n',log='y',xlab='Components',ylab='Seconds',main=dataset)
    fams <- c('plssvd','simpls','opls','kernelpls')
    for(j in seq_along(fams))for(back in c('cpu','metal')){
        u <- a[a$method==fams[j]&a$backend_requested==back,];u <- u[order(u$ncomp),]
        if(nrow(u))lines(u$ncomp,u$median_total_sec,col=cols[j],lty=if(back=='cpu')1 else 2)
    }
}
plot.new();legend('center',c('PLS-SVD','SIMPLS','OPLS','Kernel PLS','CPU solid; Metal dashed'),col=c(cols,'black'),lty=c(rep(1,4),2),bty='n')
dev.off()
