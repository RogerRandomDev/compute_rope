#[compute]
#version 450
// Invocations in the (x, y, z) dimension
layout(local_size_x = 16) in;


const vec2 gravity=vec2(0.0,128.0);

struct rope_segment {
    float lastx,lasty;
    float rest_length;
    float point_weight;
    float last_update_x;
    float last_update_y;
    float rope_id;
};
struct min_rope_seg {
    float x,y;
};


struct force_application {
    float x,y;
    float range;
    float force;
};



layout(set = 0, binding = 0, std430) restrict buffer RopeSegments{
    rope_segment data[];
}
rope_segments;

layout(set = 0, binding = 1, std430) restrict buffer manage_data{
    float time_step;
    float detail_level;
    float accuracy;
    float cur_time;
    force_application forces[];
}managed;

layout(set = 1, binding = 2) restrict buffer cpuGrabbed{
    min_rope_seg data[];
}
cpu_grabbed;
layout(set = 2, binding = 0, r8) uniform restrict readonly image2D mapImage;



layout(push_constant, std430) uniform Params {
	uint cur_step;
    uint segment_count;
} params;



bool collision_map_includes(vec2 pos){
    return imageLoad(mapImage,ivec2(pos*0.03125)).r!=0;
}
vec2 clamp_within_map_grid(vec2 coord,vec2 start_from){
    
    return clamp(
        coord,vec2(ivec2(start_from*0.03125))*32.0+vec2(0.125,0.125),vec2(ivec2(start_from*0.03125))*32.0+vec2(31.875,31.875)
    );
}




float rand(vec2 n) { 
	return fract(sin(dot(n, vec2(12.9898, 4.1414))) * 43758.5453);
}

float noise(vec2 p){
	vec2 ip = floor(p);
	vec2 u = fract(p);
	u = u*u*(3.0-2.0*u);
	
	float res = mix(
		mix(rand(ip),rand(ip+vec2(1.0,0.0)),u.x),
		mix(rand(ip+vec2(0.0,1.0)),rand(ip+vec2(1.0,1.0)),u.x),u.y);
	return ((res*res)-0.5);
}



vec2 get_turbulence_at(uint point_id) {
    return vec2(noise(vec2(point_id,managed.cur_time)),noise(vec2(managed.cur_time,point_id)))*8.0;
}

float length_squared(vec2 s){
    return (s.x*s.x+s.y*s.y);
}


float distance_squared_to(vec2 p1, vec2 p2){
    return ((p1.x-p2.x)*(p1.x-p2.x)+(p1.y-p2.y)*(p1.y-p2.y));
}

vec2 get_forces_at(vec2 position) {
    vec2 applied_force=vec2(0.0,0.0);
    for(uint i=0;i<64;i++){
        force_application applied=managed.forces[i];
        if(applied.force.x==0) break;
        if(distance_squared_to(position,vec2(applied.x,applied.y))>applied.range*applied.range) continue;
        vec2 norm=position-vec2(applied.x,applied.y);
        // float norm_length=length(
        //     norm
        // );
        vec2 normal=normalize(norm);
        // if(norm_length<applied.range){
        applied_force+=applied.force*normal;
        // }
    }
    return applied_force;
}





void verlet_rope(uint rope_id) {
    rope_segment editing=rope_segments.data[rope_id];
    min_rope_seg editing_min=cpu_grabbed.data[rope_id];
    vec2 temp=vec2(editing_min.x,editing_min.y);

    vec2 acceleration=gravity;
    acceleration+=get_turbulence_at(rope_id);
    acceleration+=get_forces_at(temp);

    vec2 edited_to = 2*temp-vec2(editing.lastx,editing.lasty) + acceleration*managed.time_step*managed.time_step;

    if(collision_map_includes(edited_to)){    
        edited_to=clamp_within_map_grid(edited_to,vec2(editing.lastx,editing.lasty));
    }
    rope_segments.data[rope_id].lastx=temp.x;
    rope_segments.data[rope_id].lasty=temp.y;
    cpu_grabbed.data[rope_id].x=edited_to.x;
    cpu_grabbed.data[rope_id].y=edited_to.y;
    

    // rope_segments.data[rope_id]=editing;
    // cpu_grabbed.data[rope_id]=editing_min;
}



vec2[2] get_contrain_force(rope_segment seg_a, rope_segment seg_b,min_rope_seg min_a,min_rope_seg min_b){
    vec2 p_a=vec2(min_a.x,min_a.y);
    vec2 p_b=vec2(min_b.x,min_b.y);
    vec2 delta= p_b-p_a;
    float deltalength = sqrt((delta.x*delta.x)+(delta.y*delta.y));
    float diff = (deltalength-seg_a.rest_length)/(deltalength*(seg_a.point_weight+seg_b.point_weight));



    p_a += delta * seg_a.point_weight * diff;
    p_b -= delta * seg_b.point_weight * diff;

    vec2[2] p_set={p_a,p_b};
    return p_set;
}


void satisfy_constraints(uint rope_id){
    rope_segment seg_a=rope_segments.data[rope_id];
    min_rope_seg min_a=cpu_grabbed.data[rope_id];
    if(seg_a.point_weight>0&&length_squared(vec2(seg_a.last_update_x-min_a.x,seg_a.last_update_y-min_a.y))<0.2) return;
    if(rope_id>0){
        min_rope_seg min_b=cpu_grabbed.data[rope_id-1];
        rope_segment seg_b=rope_segments.data[rope_id-1];
        if(seg_b.rope_id!=seg_a.rope_id){return;}
        vec2[2] p=get_contrain_force(seg_a,seg_b,min_a,min_b);
        if(collision_map_includes(p[0])) p[0]=clamp_within_map_grid(p[0],vec2(min_a.x,min_a.y));
        if(collision_map_includes(p[1])) p[1]=clamp_within_map_grid(p[1],vec2(min_b.x,min_b.y));
        cpu_grabbed.data[rope_id].x=p[0].x;
        cpu_grabbed.data[rope_id].y=p[0].y;
        cpu_grabbed.data[rope_id-1].x=p[1].x;
        cpu_grabbed.data[rope_id-1].y=p[1].y;
        min_a=cpu_grabbed.data[rope_id];
        // cpu_grabbed.data[rope_id]=min_a;
        // cpu_grabbed.data[rope_id-1]=min_b;
    }
    
    if(rope_id<params.segment_count-1){
        min_rope_seg min_b=cpu_grabbed.data[rope_id+1];
        rope_segment seg_b=rope_segments.data[rope_id+1];
        if(seg_b.rope_id!=seg_a.rope_id){return;}
        vec2[2] p=get_contrain_force(seg_a,seg_b,min_a,min_b);
        if(collision_map_includes(p[0])) p[0]=clamp_within_map_grid(p[0],vec2(min_a.x,min_a.y));
        if(collision_map_includes(p[1])) p[1]=clamp_within_map_grid(p[1],vec2(min_b.x,min_b.y));
        cpu_grabbed.data[rope_id].x=p[0].x;
        cpu_grabbed.data[rope_id].y=p[0].y;
        cpu_grabbed.data[rope_id+1].x=p[1].x;
        cpu_grabbed.data[rope_id+1].y=p[1].y;
        // cpu_grabbed.data[rope_id]=min_a;
        // cpu_grabbed.data[rope_id-1]=min_b;
    }



   

    
}





// The code we want to execute in each invocation
void main() {
    uint start_from=(gl_GlobalInvocationID.x*4);
    if(start_from>params.segment_count) return;

    // if((gl_GlobalInvocationID.x*8)%clamp_limit!=(gl_GlobalInvocationID.x*8)) start_from-=start_from%8;

    uint loop_count=min(params.segment_count-start_from,4);
    for(uint i=0;i<loop_count;i++){
        if(rope_segments.data[start_from+i].point_weight>0) verlet_rope(start_from+i);
    }
    for(uint j=0;j<50;j++)
    {
    for(uint i=0;i<4;i++){
        satisfy_constraints(start_from+i);
        
    }
    }
    // for(uint i=0;i<4;i++){
    //     if(start_from+i==0) continue;
    //     min_rope_seg seg_a=cpu_grabbed.data[start_from+i];
    //     min_rope_seg seg_b=cpu_grabbed.data[start_from+i-1];
        
    //     vec2 dir=normalize(
    //         vec2(seg_a.x,seg_a.y)-vec2(seg_b.x,seg_b.y));
    //     float len=length(vec2(seg_a.x,seg_a.y)-vec2(seg_b.x,seg_b.y));
    //     seg_a.x=len*dir.x+seg_b.x;
    //     seg_a.y=len*dir.y+seg_b.y;
    //     cpu_grabbed.data[start_from+i]=seg_a;

    // }
}

