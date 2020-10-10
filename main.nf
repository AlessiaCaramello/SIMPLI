nextflow.enable.dsl=2

script_folder = "$baseDir/scripts"

include {singularity_key_getter} from "$script_folder/workflows.nf"
include {convert_metadata_to_cp3} from "$script_folder/workflows.nf"

include {convert_raw_data} from "$script_folder/workflows.nf"

include {normalize_images} from "$script_folder/workflows.nf"

include {preprocess_images} from "$script_folder/workflows.nf"

include {measure_areas} from "$script_folder/workflows.nf"

include {segment_cells} from "$script_folder/workflows.nf"

include {identify_cell_types_mask} from "$script_folder/workflows.nf"
include {identify_cell_types_expression} from "$script_folder/workflows.nf"

include {cluster_cells} from "$script_folder/workflows.nf"

include {visualize_areas} from "$script_folder/workflows.nf"
include {visualize_cell_types} from "$script_folder/workflows.nf"
include {visualize_cell_clusters} from "$script_folder/workflows.nf"

workflow {
    sample_names = channel.fromPath(params.sample_metadata_file).splitCsv(header: true).map{row -> row.sample_name}
    singularity_key_getter()
    if(params.raw_metadata_file && !params.skip_conversion){
        convert_raw_data(singularity_key_getter.out.singularity_key_got)
    }    
    if((params.converted_metadata_file || !params.skip_conversion) && !params.skip_normalization){
        normalization_metadata = (params.skip_conversion) ? channel.fromPath(params.converted_metadata_file) : convert_raw_data.out.converted_tiff_metadata
        normalize_images(singularity_key_getter.out.singularity_key_got, sample_names, normalization_metadata)
    }    
    if(!params.skip_preprocessing){
        if(!params.skip_normalization){
            preprocessing_metadata = normalize_images.out.cp3_normalized_tiff_metadata_by_sample
        }
        else if(params.skip_normalization && !params.skip_conversion){
            convert_metadata_to_cp3(singularity_key_getter.out.singularity_key_got, "-cp3_metadata.csv", convert_raw_data.out.converted_tiff_metadata.collect()) 
            preprocessing_metadata = convert_metadata_to_cp3.out.cp3_metadata.flatten()
        }    
        else{
            metadata_to_convert = channel.fromPath(params.normalized_metadata_file)
            convert_metadata_to_cp3(singularity_key_getter.out.singularity_key_got, "-cp3_metadata.csv", metadata_to_convert) 
            preprocessing_metadata = convert_metadata_to_cp3.out.cp3_metadata.flatten()
        }
        preprocessing_metadata = preprocessing_metadata
            .map{ file ->
                def key = file.name.toString().tokenize('-').get(0)
                return tuple(key, file)
            }
            .groupTuple()
        preprocess_images(singularity_key_getter.out.singularity_key_got, preprocessing_metadata) 
    }    
    if(!params.skip_area){
        if(!params.skip_preprocessing){
            area_measurement_metadata = preprocess_images.out.preprocessed_tiff_metadata
        }    
        else{
            area_measurement_metadata = params.preprocessed_metadata_file
        }
        measure_areas(singularity_key_getter.out.singularity_key_got, area_measurement_metadata, params.area_measurements_metadata)
    }    
    if(!params.skip_segmentation){
        if(!params.skip_preprocessing)
            segmentation_metadata = preprocess_images.out.cp3_preprocessed_tiff_metadata_by_sample
        else{
            convert_metadata_to_cp3(singularity_key_getter.out.singularity_key_got, "-cp3_metadata.csv", params.preprocessed_metadata_file) 
            segmentation_metadata = convert_metadata_to_cp3.out.cp3_metadata
        }
        segmentation_metadata = segmentation_metadata.flatten()
            .map { file ->
                def key = file.name.toString().tokenize('-').get(0)
                return tuple(key, file)
             }
            .groupTuple()
        segment_cells(singularity_key_getter.out.singularity_key_got, segmentation_metadata)
    }    
    if(!params.skip_cell_type_identification){
        if(!params.skip_segmentation)
            unannotated_cells = segment_cells.out.unannotated_cell_data
        else{
            unannotated_cells = params.single_cell_data_file
        }
        if(params.cell_identification_method == "mask"){
            if(!params.skip_segmentation)
                cell_mask_metadata = segment_cells.out.cell_mask_metadata
            else{
                cell_mask_metadata = params.single_cell_masks_metadata
            }
            if(!params.skip_preprocessing)
                image_metadata = preprocess_images.out.preprocessed_tiff_metadata
            else{
                image_metadata = params.preprocessed_metadata_file
            }
            identify_cell_types_mask(singularity_key_getter.out.singularity_key_got, unannotated_cells, params.cell_analysis_metadata,
                image_metadata, cell_mask_metadata)
            annotated_cell_data = identify_cell_types_mask.out.annotated_cell_data
        }
        if(params.cell_identification_method == "expression"){
            identify_cell_types_expression(singularity_key_getter.out.singularity_key_got, unannotated_cells, params.cell_analysis_metadata)
            annotated_cell_data = identify_cell_types_expression.out.annotated_cell_data
        }    
    }    
    if(!params.skip_cell_clustering){
        if(!params.skip_cell_type_identification)
            annotated_cells = annotated_cell_data 
        else{
            annotated_cells = params.annotated_cell_data_file
        }
        clustering_metadata = channel.fromPath(params.cell_analysis_metadata)
            .splitCsv(header:true)
            .map{row -> tuple(row.cell_type, row.clustering_markers, row.clustering_resolutions)}
            .filter{!it.contains("NA")}
        cluster_cells(singularity_key_getter.out.singularity_key_got, annotated_cells, clustering_metadata, params.sample_metadata_file)
    }    
    if(!params.skip_visualization){
        if(!params.skip_area && !params.skip_area_visualization){
            visualize_areas(singularity_key_getter.out.singularity_key_got, measure_areas.out.area_measurements,
                params.sample_metadata_file)
        }
        if(!params.skip_type_visualization){
            if(!params.skip_segmentation){
                cell_masks = segment_cells.out.cell_mask_tiffs.collect()
            }
            if(params.skip_segmentation){
                cell_masks = channel.fromPath(params.single_cell_masks_metadata)
                    .splitCsv(header:true)
                    .map{row -> row.file_name}
                    .collect() 
            }
            if(!params.skip_cell_type_identification){
                cell_types = annotated_cell_data 
            }
            if(params.skip_cell_type_identification){
                cell_types = params.annotated_cell_data_file
            }
            visualize_cell_types(singularity_key_getter.out.singularity_key_got, cell_types,
                params.sample_metadata_file, params.cell_analysis_metadata, cell_masks)
        }
        if(!params.skip_cluster_visualization){
            if(!params.skip_cell_clustering){
                clustered_cell_file = cluster_cells.out.clustered_cell_data
            }
            else{
                clustered_cell_file = params.clustered_cell_data_file
            }
            clustering_metadata = channel.fromPath(params.cell_analysis_metadata)
                .splitCsv(header:true)
                .map{row -> tuple(row.cell_type, row.clustering_markers, row.clustering_resolutions)}
                .filter{!it.contains("NA")}
            visualize_cell_clusters(singularity_key_getter.out.singularity_key_got, clustering_metadata,
                clustered_cell_file, params.sample_metadata_file)
        }
    }
}
