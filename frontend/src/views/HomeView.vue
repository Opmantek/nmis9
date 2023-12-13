<template>
    <div class="container-fluid">
        <div class="row">
            <div class="col-md-3 col-sm-12">
                <div class="row">
                    <div class="col-12">
                        <NodeSearch></NodeSearch>
                    </div>
                    <div class="col-12 mt-3">
                        <Community></Community>
                    </div>
                </div>                
            </div>
            <div class="col-md-9 col-sm-12">
                <div class="row">
                    <div class="col-12">
                        <div class="card">
                            <div class="card-header">
                                <div class="card-title">
                                   Metrics and Health
                                </div>
                            </div>
                            <div class="card-body">
                                Metrics and health chart goes here
                            </div>
                        </div>
                    </div>
                    <div class="col-12 mt-3">
                        <div class="card">
                            <div class="card-header">
                                <div class="card-title">
                                   Log
                                </div>
                            </div>
                            <div class="card-body">
                                Log grid goes here
                            </div>
                        </div>
                    </div>
                </div> 
            </div>
        </div>
    </div>

</template>

<script>
    import NodeSearch from '@/components/NodeSearch.vue';
    import Community from '../components/Community.vue';

    export default {
        components: {
            NodeSearch,
            Community
        }
    }

</script>