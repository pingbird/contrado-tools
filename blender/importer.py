import bpy
import bmesh
import os
import numpy as np
from PIL import Image, ImageDraw
import json

model_path = r'C:\Users\ping\IdeaProjects\contrado-tools\contrado_dl\cache\products\1614\M_10_12UK\Skater_Dress.glb'
model_config_path = r'C:\Users\ping\IdeaProjects\contrado-tools\contrado_dl\cache\products\1614\model_config.json'
template_config_path = r'C:\Users\ping\IdeaProjects\contrado-tools\contrado_dl\cache\products\1614\M_10_12UK\template.json'
project_path = r'C:\Users\ping\Documents\art\vhs_doggy'

with open(model_config_path) as f:
    model_config = json.load(f)

with open(template_config_path) as f:
    template_config = json.load(f)

bpy.ops.import_scene.gltf(filepath=model_path)

bpy.ops.object.select_all(action='DESELECT')

for obj in bpy.context.scene.objects:
    if obj.type == 'MESH' and obj.name.lower().startswith("template"):
        obj.select_set(True)

bpy.context.view_layer.objects.active = bpy.context.selected_objects[0]

bpy.ops.object.join()

bpy.context.view_layer.objects.active.name = "Template"

template_object = bpy.data.objects.get("Template")
template_mat = bpy.data.materials.new(name="Template_Material")
template_mat.use_nodes = True
nodes = template_mat.node_tree.nodes
links = template_mat.node_tree.links

template_object.data.materials.clear()
template_object.data.materials.append(template_mat)

image_dpi = 200
uv_size = 4096

coord_node = nodes.new('ShaderNodeTexCoord')

section_idx = 0
colors = [
    (0.9, 0.5, 0.5, 1.0),
    (0.9, 0.55, 0.45, 1.0),
    (0.9, 0.6, 0.4, 1.0),
    (0.9, 0.75, 0.45, 1.0),
    (0.9, 0.9, 0.5, 1.0),
    (0.7, 0.9, 0.5, 1.0),
    (0.5, 0.9, 0.5, 1.0),
    (0.5, 0.8, 0.7, 1.0),
    (0.5, 0.7, 0.9, 1.0),
    (0.55, 0.6, 0.9, 1.0),
    (0.6, 0.5, 0.9, 1.0),
    (0.7, 0.5, 0.9, 1.0),
    (0.8, 0.5, 0.9, 1.0)
]



def create_image_node(name, x0, y0, x1, y1, image_size):
    global section_idx
    fill_color = colors[section_idx]
    section_idx += 1
    img = Image.new("RGBA", (image_size, image_size), (round(fill_color[0] * 255), round(fill_color[1] * 255), round(fill_color[2] * 255)))
    img_draw = ImageDraw.Draw(img)

    me = template_object.data
    uv_layer = me.uv_layers.active.data

    edges = []

    for poly in me.polygons:
        poly_uvs = [uv_layer[loop_index].uv for loop_index in poly.loop_indices]
        for i in range(len(poly.vertices)):
            edge = (poly_uvs[i], poly_uvs[(i+1) % len(poly.vertices)])
            edges.append(edge)

    xoffset = x0 / uv_size
    yoffset = 1 - (y1 / uv_size)
    yoffset2 = y1 / uv_size
    xsize = (x1 - x0) / uv_size
    ysize = (y1 - y0) / uv_size

    for edge in edges:
        img_draw.line([
            (
                (edge[0][0] - xoffset) * image_size / xsize,
                (edge[0][1] - yoffset) * image_size / ysize
            ),
            (
                (edge[1][0] - xoffset) * image_size / xsize,
                (edge[1][1] - yoffset) * image_size / ysize
            ),
        ], fill ="white", width = 2)

    image_data = bpy.data.images.new(name, width=image_size, height=image_size)
    image_data.pixels = (np.array(img) / 255.0).ravel()
    image_data.file_format = "PNG"
    image_data.filepath_raw = f'{project_path}\\{section_idx}.png'
    # image_data.filepath = f'{project_path}\\{i}.png'
    image_data.save()

    texture_node = nodes.new(type='ShaderNodeTexImage')
    texture_node.image = image_data
    texture_node.extension = "CLIP"

    mapping_node = nodes.new('ShaderNodeMapping')
    mapping_node.vector_type = 'TEXTURE'

    mapping_node.inputs[1].default_value[0] = xoffset
    mapping_node.inputs[1].default_value[1] = yoffset
    mapping_node.inputs[3].default_value[0] = xsize
    mapping_node.inputs[3].default_value[1] = ysize

    links.new(coord_node.outputs['UV'], mapping_node.inputs['Vector'])
    links.new(mapping_node.outputs['Vector'], texture_node.inputs['Vector'])

    return texture_node

last_output = None

for idx, field_data in enumerate(model_config['ProductFeilds']):
    template_field = template_config["fields"][idx]
    printq = template_config["printq"]
    rulerPadding = (300 / 420) * 21
    maxSizeInPixel = max(template_field["printw"] * template_field["editablefield"]["width"], template_field["printh"] * template_field["editablefield"]["height"])
    maxDimension = maxSizeInPixel / printq
    maskSize = max(template_field["originalMask"]["width"], template_field["originalMask"]["height"]) + rulerPadding
    rulerSize = (maskSize * maxDimension / (maskSize - rulerPadding))
    image_size = rulerSize * image_dpi

    node = create_image_node(
        field_data['Name'],
        field_data['UvImageCoordinates']['X0'],
        field_data['UvImageCoordinates']['Y0'],
        field_data['UvImageCoordinates']['X1'],
        field_data['UvImageCoordinates']['Y1'],
        round(image_size)
    )
    if last_output is None:
        last_output = node.outputs['Color']
    else:
        mix_node = nodes.new('ShaderNodeMixRGB')
        mix_node.blend_type = 'MIX'

        links.new(node.outputs['Alpha'], mix_node.inputs[0])
        links.new(last_output, mix_node.inputs[1])
        links.new(node.outputs['Color'], mix_node.inputs[2])

        last_output = mix_node.outputs['Color']

bsdf_node = nodes.get("Principled BSDF")
links.new(last_output, bsdf_node.inputs['Base Color'])

bpy.context.view_layer.update()
