# OpenStack & AWX Automation Lab / Laboratorio de Automatización

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Ansible](https://img.shields.io/badge/Ansible-2.9%2B-red)](https://www.ansible.com/)
[![OpenStack](https://img.shields.io/badge/OpenStack-2024.1-orange)](https://www.openstack.org/)

**(English below)**

## 🇪🇸 Descripción del Proyecto
Este repositorio documenta el despliegue y automatización de una nube privada utilizando **OpenStack (Kolla-Ansible)** y **AWX (Ansible Tower)** sobre **CentOS 9 Stream**.

El objetivo es pasar de una infraestructura manual a un modelo **IaaS (Infrastructure as a Service)** totalmente automatizado mediante código (IaC).

### 🏗 Arquitectura
*   **Hypervisor:** VMware Workstation.
*   **OS:** CentOS Stream 9.
*   **Red:**
    *   `ens33` (NAT): Gestión y Salida a Internet.
    *   `ens34` (LAN Segment): Red interna de tráfico de VMs (Provider Network).
*   **Almacenamiento:** LVM Cinder Backend (Disco secundario dedicado).

### 📂 Estructura del Repositorio
*   `/scripts`: Scripts Bash para el despliegue automático de OpenStack y AWX.
*   `/playbooks`: Ejercicios de Ansible para operar la nube (crear usuarios, redes, instancias...).
*   `/configs`: Plantillas de configuración (clouds.yaml, etc).

### ✅ Progreso (Nivel Básico Completado)
1.  **Despliegue de Infraestructura:** OpenStack All-in-One funcional.
2.  **Despliegue de Gestión:** AWX corriendo en contenedores Docker.
3.  **Automatización (Playbooks):**
    *   [x] 01_test.yml: Verificación de conexión API.
    *   [x] 02_crear_proyecto.yml: Creación de Tenants.
    *   [x] 03_crear_usuario.yml: Gestión de IAM (Usuarios y Roles).
    *   [x] 04_crear_flavor.yml: Definición de catálogo de hardware.
    *   [x] 05_crear_red.yml: SDN (Redes privadas y Subnets).
    *   [x] 06_subir_imagen.yml: Gestión de imágenes (Glance).
    *   [x] 07_seguridad.yml: Configuración de Security Groups (Firewall).
    *   [x] 08_lanzar_instancia.yml: Despliegue completo de VM con Floating IP.

---

## 🇬🇧 Project Description
This repository documents the deployment and automation of a private cloud using **OpenStack (Kolla-Ansible)** and **AWX (Ansible Tower)** on **CentOS 9 Stream**.

The goal is to transition from manual infrastructure to a fully automated **IaaS (Infrastructure as a Service)** model using Infrastructure as Code (IaC).

### 🏗 Architecture
*   **Hypervisor:** VMware Workstation.
*   **OS:** CentOS Stream 9.
*   **Network:**
    *   `ens33` (NAT): Management & Internet Access.
    *   `ens34` (LAN Segment): Internal VM traffic (Provider Network).
*   **Storage:** LVM Cinder Backend (Dedicated secondary disk).

### 📂 Repository Structure
*   `/scripts`: Bash scripts for automatic deployment of OpenStack and AWX.
*   `/playbooks`: Ansible exercises to operate the cloud (create users, networks, instances...).
*   `/configs`: Configuration templates (clouds.yaml, etc).

### ✅ Progress (Basic Level Completed)
1.  **Infrastructure Deployment:** Functional OpenStack All-in-One.
2.  **Management Deployment:** AWX running on Docker containers.
3.  **Automation (Playbooks):**
    *   [x] 01_test.yml: API connection verification.
    *   [x] 02_crear_proyecto.yml: Tenant creation.
    *   [x] 03_crear_usuario.yml: IAM Management (Users & Roles).
    *   [x] 04_crear_flavor.yml: Hardware catalog definition.
    *   [x] 05_crear_red.yml: SDN (Private Networks & Subnets).
    *   [x] 06_subir_imagen.yml: Image management (Glance).
    *   [x] 07_seguridad.yml: Security Groups configuration (Firewall).
    *   [x] 08_lanzar_instancia.yml: Full VM deployment with Floating IP.
