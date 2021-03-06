/**************************************************************************************/
LIBNAME reco'/folders/myfolders/KNN/Data'; 		/* Data directory specification       */  
%let InDS= reco._base;							/* Basic DataSet                      */
%let RandomSeed = 955;							/* Dividing random number seed)       */
%let k=80; 	/* default 50 */					/* Count of nearest neighbors to find */ 
/**************************************************************************************/
%let _sdtm=%sysfunc(datetime()); 					/* Store Script Start Time				*/
/********************************************************************************************/



/******************************************************/
/******************* DATA PREPARATION *****************/
/******************************************************/



/*** Sampling - divide to training (L) and testing(T) ***/
data reco.Sample;
    set &InDS;
    if _n_=1 then
        call streaminit(&randomseed);
    U=rand('uniform');
    if U<=0.80 
	then DevSample='L';
    else DevSample='T';
run;

/* Sort */
proc sort data=reco.Sample;
by UserId ItemId;
run;






/*Max & Min Ratings*/
Title3 "Max Rating";
Proc sql noprint;
select max(rating)
into: MaxRating
from &InDS;
quit;

Title3 "Min Rating";
Proc sql noprint;
select min(rating)
into: MinRating
from &InDS;
quit;



/*AVG Rating to variable: AvgRating */
Title3 "AVG DataSet Rating";
proc sql;
SELECT AVG(Rating) 
Into: AvgRating 
FROM reco.Sample
where DevSample= "L";
quit;

/*AVG Item Rating */
proc sql;
create table reco.AVG_ItemID as 
select ItemID, avg (Rating) as AvgRatingOnItem
from reco.Sample
where DevSample = "L" group by ItemID;
quit;

/*AVG User Rating */
proc sql;
create table reco.AVG_UserID as 
select UserID, avg (Rating) as AvgUserRating, avg (Rating) - &AvgRating as Bias
from reco.Sample 
where DevSample = "L" group by UserID;
quit;


/*** Sparse to dense ***/
proc iml;
/* Read data*/
use reco.sample;
read all var{Rating UserId ItemId} where(DevSample="L");
close;
/* combine UserId ItemId Rating into a sparse matrix */
/*       Value	||	Row	  ||  Col     				 */
sparse = Rating || UserId || ItemId;

/* Conversion sparse to dense matrix*/
/*			ItemID   				*/
/*	UserID	Rating          		*/
dense = full(sparse);
/* Store data */
create reco.base_dense from dense;
append from dense;
close reco.base_dense;
quit;

/*** Rating: Set missing values instead 0 ***/
data reco.base_dense_null; 
set reco.base_dense;
array nums _numeric_;
 
do over nums;
 if nums=0 then nums=.;	
end;
run;





/******************************************************/
/********************* COMPUTING **********************/
/******************************************************/


/* Store Recommendation Start Time	*/
%let _recostart=%sysfunc(datetime()); 					


/* Item AVG to Missing rating */   /*******************************************************************    null >>> ItemAVG     */
/* base_dense_avged       OUT */
/* base_dense_null        IN  */

proc iml;
use reco.base_dense_null;
read all into rating;
close;

do item = 1 to ncol(rating);
	if countn(rating[ ,item]) ^=. then do;		
		itemAVG =  mean(rating[ ,item]);
		do replacement = 1 to nrow(rating);
			if rating [replacement ,item] =. then do;
					rating [replacement ,item] = itemAVG ;
			end;
		end;
	end;
	if countn(rating[ ,item]) =0 then do;
	rating[ ,item] = &AvgRating;
	end;
end;
	
create reco.base_dense_avged from rating ;
append from rating ;
close reco.base_dense_avged;
quit;	





/*** k-NN ***************************************************************************************************        k-NN       */
/* reco.knn_all  			    OUT */
/* reco.base_dense_avged        IN  */
proc iml;
/* Read data */
use reco.base_dense_avged  ;
read all var _num_ into rating;
close;

/* Settings */
k = &k; 


/* Initialisation */
nearestNeighbor = J(nrow(rating), k, 0); 		/* Matrix of nearest neighbors */
recommendation = J(nrow(rating), ncol(rating), 0);	/* Matrix with the estimated rating */
distance = J(nrow(rating), 1, 10**10); 			/* Vector of distances */

/* Loop - get the nearest neighbours */
do reference = 1 to nrow(rating);
	/* Measure distance, in this case Euclidean */
	do tested = 1 to nrow(rating);
		if reference ^= tested then do;
			distance[tested] = sum((rating[reference,]-rating[tested,])##2);
		end; else do;
			distance[tested] = 10**10; 	/* Some big value */
		end;
	end;

	/* Sort distances in ascending order, return indices */
	call sortndx(ndx, distance, {1});
	
	/* Store k nearest neighbours */
	nearestNeighbor[reference,] = ndx[1:k]`;

	/* Get recommendation (average recommendation of the nearest neighbours) */
	recommendation[reference,] = mean(rating[nearestNeighbor[reference,],]);
end;		

/* Convert dense to sparse matrix */
result = sparse(recommendation); 

/* Store data */
create reco.knn_all from result;
append from result;
close reco.knn_all;

quit;


/* Rename columns */
proc datasets library=reco nolist;
modify knn_all;
rename Col1 = PredRating;
rename Col2 = UserId;
rename Col3 = ItemId;
quit;


/* Debias k-NN rating prediction and bound to limits */
data reco.knn_all_debiased  /view=reco.knn_all_debiased;
	 merge reco.knn_all     (keep=UserID ItemID PredRating in=a)
		   reco.AVG_UserID  (keep=UserId Bias in=b);
	 by UserId;
	 if a & b;
	 PredRating = PredRating + Bias;
	/* PredRatingBounded = min(max(PredRating, &MinRating ),&MaxRating); */
run;

/* Measure recommendation elapsed time */
%let _recoend=%sysfunc(datetime());
%let _recoruntm=%sysfunc(putn(&_recoend - &_recostart, 12.4));
%put It took &_recoruntm second to do recommendations;
Title3 "Elapsed time";
proc iml;
print "It took " &_recoruntm"second to do recommendations";
quit;




/******************************************************/
/********************* EVALUATION *********************/
/******************************************************/


 
/* Data to evaluate*/
%let PredRating = PredRating;		/* PredRatingBounded */
%let tableName  = reco.knn_all_debiased; /* reco.knn_all_debiased_II */

 
/* Merge target and prediction & calculate Square Error */
data reco.rmse_merged(keep=SquareDiff Rating &PredRating Diff);
     merge reco.sample(keep=UserId ItemID Rating DevSample where=(DevSample="T") in=a)
           &tableName(keep=UserId ItemID &PredRating in=b);
     by UserId ItemID;
     if a & b;
     SquareDiff = (Rating-&PredRating)*(Rating-&PredRating);
     Diff 		= round(sqrt((Rating-&PredRating )*(Rating-&PredRating )));
run;


Title3 "RMSE";
/* Print RMSE */
proc sql;
select sqrt(avg(SquareDiff))
into: RMSE
from reco.rmse_merged;
quit;


/* Report Prediction Succes */
Title3 "Differences: Success, Diff1-Diff4, SUM";
proc iml;
use reco.rmse_merged;
read all var {Diff} into diff;
close; 

t = countn (diff);

counts = J(2, 6, 0);

	do d = 1 to 5;
		c=0;
		do dr = 1 to nrow(diff);
			if diff[dr] = d-1 then do;
				c = c+1;
			end;
		end;
		
		p = 100 * c / t;
		counts[1,d] = c;
		counts[2,d] = p;	
	end;
counts[1,6] = sum (counts [1, ]);
counts[2,6] = sum (counts [2, ]);
print counts;

create reco.counts from counts;
append from counts;
close reco.counts;

quit;


/* Report Prediction Succes FOR EXCEL*/
Title3 "Differences: Success, Diff1-Diff4, SUM, FOR EXCEL " ;
proc iml;
use reco.counts ;
read all var _all_ into counts;
close; 

fruifulness = counts`;
fruifulness [ ,2]  = fruifulness [ ,2] / 100;
print fruifulness;
quit;


/* Measure elapsed time */
%let _edtm=%sysfunc(datetime());
%let _runtm=%sysfunc(putn(&_edtm - &_sdtm, 12.4));
%put It took &_runtm second to run the script;
Title3 "Elapsed time";
proc iml;
print "It took " &_runtm "second to run the script";
quit;
