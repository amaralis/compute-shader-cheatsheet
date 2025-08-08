#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

struct Entity {
    vec4 dir_val; // dir.xyz + val
    vec4 pos;
};

// SSBO 0: one int per entity, although it's all the same
layout(std430, set = 0, binding = 0) buffer DirPosVal {
    Entity entities[];
} ents;

// SSBO 1: total entity count
layout(std430, set = 0, binding = 1) buffer Total {
    int num;
} nums;

// The code we want to execute in each invocation
void main() {
    uint id = gl_GlobalInvocationID.x;

    // I only have one number in this uniform. Is this the right method and syntax to access this number?
    if(id >= nums.num){
        return;
    }

    Entity e = ents.entities[id];
    vec3 dir = e.dir_val.xyz;
    float val = e.dir_val.w;
    vec3 pos = e.pos.xyz;

    // Example: just add 1
    dir += 1.0;
    val += 1.0;
    pos += 1.0;

    ents.entities[id].dir_val.xyz = dir;
    ents.entities[id].dir_val.w = val;
    ents.entities[id].pos.xyz = pos;
}
